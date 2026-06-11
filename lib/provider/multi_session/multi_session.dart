import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/models/multi_session/multi_session.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/metadata_plugin/core/user.dart';
import 'package:spotube/provider/server/sourced_track_provider.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/device_info/device_info.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

class MultiSessionNotifier extends Notifier<MultiSessionState> {
  static const _legacyRelayUrl = "https://spotube-multi-session.workers.dev";
  static const _remoteSeekThresholdMs = 4000;
  static const _stringListEquality = ListEquality<String>();

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _positionTimer;
  Timer? _reconnectTimer;
  bool _applyingRemote = false;
  bool _closingRoom = false;
  bool _intentionalDisconnect = false;
  int _connectionGeneration = 0;
  int? _lastObservedPositionMs;
  DateTime? _lastObservedAt;
  final Set<String> _failedSessionTracks = {};

  void _debugTrace(String message) {
    if (!kDebugMode) return;
    // ignore: avoid_print
    print('[multi-session] $message');
  }

  MultiSessionUiNotice _buildNotice(
    String message, {
    bool destructive = false,
  }) {
    return MultiSessionUiNotice(
      message: message,
      destructive: destructive,
      id: DateTime.now().microsecondsSinceEpoch,
    );
  }

  void _pushNotice(
    String message, {
    bool destructive = false,
  }) {
    state = state.copyWith(
      notice: _buildNotice(message, destructive: destructive),
    );
  }

  bool _guardPermission(
    MultiSessionPermission permission,
    String actionLabel,
  ) {
    if (state.can(permission)) return true;

    _pushNotice(
      "You don't have permission to $actionLabel in this room.",
      destructive: true,
    );
    return false;
  }

  bool get _canControlPlayback =>
      state.connected &&
      !_applyingRemote &&
      state.can(MultiSessionPermission.controlPlayback);

  bool get _canEditQueue =>
      state.connected &&
      !_applyingRemote &&
      state.can(MultiSessionPermission.editQueue);

  void _rememberObservedPosition(Duration position) {
    _lastObservedPositionMs = position.inMilliseconds;
    _lastObservedAt = DateTime.now();
  }

  List<String> _queueIds(List<Map<String, dynamic>> queue) {
    return queue
        .map((item) => item["id"]?.toString() ?? "")
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
  }

  List<String> _memberSignatures(List<MultiSessionMember> members) {
    return members
        .map((member) =>
            "${member.id}:${member.role}:${member.preset.name}:${member.permissions.values.join(",")}")
        .toList(growable: false);
  }

  List<String> _suggestionSignatures(List<MultiSessionSuggestion> suggestions) {
    return suggestions
        .map((suggestion) => "${suggestion.id}:${suggestion.voteCount}")
        .toList(growable: false);
  }

  bool _isPlaybackOnlySnapshotUpdate(
    MultiSessionRoomSnapshot previous,
    MultiSessionRoomSnapshot next,
  ) {
    return previous.roomId == next.roomId &&
        previous.code == next.code &&
        previous.activeTrackId == next.activeTrackId &&
        previous.activeSource?.id == next.activeSource?.id &&
        previous.playing == next.playing &&
        previous.communityQueueEnabled == next.communityQueueEnabled &&
        _stringListEquality.equals(
            _queueIds(previous.queue), _queueIds(next.queue)) &&
        _stringListEquality.equals(
          _memberSignatures(previous.members),
          _memberSignatures(next.members),
        ) &&
        _stringListEquality.equals(
          _suggestionSignatures(previous.suggestions),
          _suggestionSignatures(next.suggestions),
        );
  }

  Future<Map<String, dynamic>?> _activeSourcePayload() async {
    final activeTrack = ref.read(audioPlayerProvider).activeTrack;
    if (activeTrack is! SpotubeFullTrackObject) return null;

    try {
      final sourcedTrack =
          await ref.read(sourcedTrackProvider(activeTrack).future);
      return sourcedTrack.info.toJson();
    } catch (error, stackTrace) {
      await AppLogger.reportError(
        error,
        stackTrace,
        "Failed to resolve active track source for multi-session sync",
      );
      return null;
    }
  }

  @override
  MultiSessionState build() {
    ref.listen(audioPlayerProvider, (previous, next) {
      if (!_canEditQueue) return;

      final previousIds = previous?.tracks.map((track) => track.id).join(",");
      final nextIds = next.tracks.map((track) => track.id).join(",");
      if (previousIds != nextIds ||
          previous?.currentIndex != next.currentIndex) {
            
        final localTrackIds =
            next.tracks.map((track) => track.id).toList(growable: false);
        final remoteTrackIds = _queueIds(state.snapshot?.queue ?? const []);
        final activeIndex = state.snapshot?.activeTrackId == null
            ? 0
            : remoteTrackIds.indexOf(state.snapshot!.activeTrackId!);
        final index = activeIndex < 0 ? 0 : activeIndex;

        final isSnapshotSync =
            _stringListEquality.equals(localTrackIds, remoteTrackIds) &&
                next.currentIndex == index;

        if (isSnapshotSync) return;

        if (previousIds != nextIds) {
          final previousTrackIds =
              previous?.tracks.map((track) => track.id).toSet() ?? <String>{};
          final addedTrack =
              next.tracks.whereType<SpotubeFullTrackObject>().firstWhereOrNull(
                    (track) => !previousTrackIds.contains(track.id),
                  );
          if (addedTrack != null) {
            _pushNotice("${addedTrack.name} added to queue by $_actorName");
          }
        }
        sendQueue();
      }
    });

    final playingSubscription = audioPlayer.playingStream.listen((playing) {
      if (!_canControlPlayback) return;
      _pushNotice(
        playing
            ? "Playback resumed by $_actorName"
            : "Playback paused by $_actorName",
      );
      _rememberObservedPosition(audioPlayer.position);
      sendPlayback();
    });

    final positionSubscription = audioPlayer.positionStream.listen((position) {
      final now = DateTime.now();
      final previousPositionMs = _lastObservedPositionMs;
      final previousObservedAt = _lastObservedAt;
      _rememberObservedPosition(position);

      if (!_canControlPlayback ||
          previousPositionMs == null ||
          previousObservedAt == null) {
        return;
      }

      final elapsedMs = now.difference(previousObservedAt).inMilliseconds;
      final expectedPositionMs =
          previousPositionMs + (audioPlayer.isPlaying ? elapsedMs : 0);

      if ((position.inMilliseconds - expectedPositionMs).abs() > 1500) {
        sendPlayback();
      }
    });

    final errorSubscription = audioPlayer.errorStream.listen((error) {
      if (!state.connected || _canControlPlayback) return;
      final playerState = ref.read(audioPlayerProvider);
      final currentTrackId = playerState.activeTrack?.id;
      if (currentTrackId != null) {
        _failedSessionTracks.add(currentTrackId);
        if (audioPlayer.isPlaying) {
          audioPlayer.pause();
        }
      }
    });

    _positionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!state.isHost) return;
      if (!_canControlPlayback) return;
      _rememberObservedPosition(audioPlayer.position);
      sendPlayback();
    });

    ref.onDispose(() {
      playingSubscription.cancel();
      positionSubscription.cancel();
      errorSubscription.cancel();
      _positionTimer?.cancel();
      _reconnectTimer?.cancel();
      _subscription?.cancel();
      _channel?.sink.close(status.goingAway);
    });

    return const MultiSessionState();
  }

  static bool _looksLikeLocalRelayHost(String value) {
    final lower = value.toLowerCase();
    return lower.startsWith("localhost") ||
        lower.startsWith("127.") ||
        lower.startsWith("[::1]") ||
        lower.startsWith("::1");
  }

  static String normalizeRelayUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return "";

    final parsed = Uri.tryParse(trimmed);
    final looksLikeAuthority = trimmed.contains("://");
    if (parsed != null && parsed.hasScheme && looksLikeAuthority) {
      return switch (parsed.scheme.toLowerCase()) {
        "ws" => parsed.replace(scheme: "http").toString(),
        "wss" => parsed.replace(scheme: "https").toString(),
        _ => parsed.toString(),
      };
    }

    final scheme = _looksLikeLocalRelayHost(trimmed) ? "http" : "https";
    final normalized = Uri.tryParse("$scheme://$trimmed");
    return normalized?.toString() ?? trimmed;
  }

  String get _relayUrl =>
      normalizeRelayUrl(ref.read(userPreferencesProvider).multiSessionRelayUrl);

  Uri _relayUri(String path, {String? relayUrl}) {
    final rawRelay = normalizeRelayUrl(relayUrl ?? _relayUrl);
    final base = Uri.parse(rawRelay.endsWith("/")
        ? rawRelay.substring(0, rawRelay.length - 1)
        : rawRelay);
    final basePath = base.path.endsWith("/")
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(path: "$basePath$path");
  }

  String? _relayConfigurationError([String? relayUrl]) {
    final value = normalizeRelayUrl(relayUrl ?? _relayUrl);
    if (value.isEmpty || value == _legacyRelayUrl) {
      return "Multi-Session relay is not configured. Open Settings > Playback > Multi-Session relay and enter a live relay URL.";
    }

    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasScheme ||
        uri.host.isEmpty ||
        !(uri.scheme == "http" || uri.scheme == "https")) {
      return "Multi-Session relay URL is invalid. Check Settings > Playback > Multi-Session relay.";
    }

    return null;
  }

  String _friendlyError(Object error) {
    final message = error.toString();
    if (message.contains("Failed host lookup") ||
        message.contains("No such host is known")) {
      return "Couldn't reach the Multi-Session relay. Check the relay URL in Settings > Playback > Multi-Session relay.";
    }

    return message;
  }

  String get _actorName => state.currentMember?.name ?? "You";

  MultiSessionMember? _memberById(String memberId) {
    return state.snapshot?.members
        .where((member) => member.id == memberId)
        .firstOrNull;
  }

  Future<String> _participantName() async {
    final user = await ref.read(metadataPluginUserProvider.future);
    final userName = user?.name.trim();
    if (userName != null && userName.isNotEmpty) {
      return userName;
    }

    return DeviceInfoService.instance.computerName();
  }

  Future<Map<String, dynamic>> _participantPayload() async {
    final user = await ref.read(metadataPluginUserProvider.future);
    final name = await _participantName();
    final images = user?.images
            .where((image) => image.url.trim().isNotEmpty)
            .map((image) => image.toJson())
            .toList() ??
        const <Map<String, dynamic>>[];
    final avatarUrl = images
        .map((image) => image["url"]?.toString())
        .firstWhereOrNull((url) => url != null && url.trim().isNotEmpty);

    return {
      "name": name,
      if (images.isNotEmpty) "images": images,
      if (avatarUrl != null) "imageUrl": avatarUrl,
      if (avatarUrl != null) "avatarUrl": avatarUrl,
      if (avatarUrl != null) "photoUrl": avatarUrl,
    };
  }

  Uri? get inviteUri {
    final code = state.code;
    final relayUrl = _relayUrl;
    if (code == null || code.isEmpty || relayUrl.isEmpty) return null;
    return MultiSessionInvite(code: code, relayUrl: relayUrl).toUri();
  }

  Future<MultiSessionRoomMetadata?> _fetchRoomMetadata(
    String code, {
    required String relayUrl,
  }) async {
    final relayConfigurationError = _relayConfigurationError(relayUrl);
    if (relayConfigurationError != null) {
      throw Exception(relayConfigurationError);
    }

    final response =
        await http.get(_relayUri("/rooms/$code", relayUrl: relayUrl));
    if (response.statusCode >= 400) {
      throw Exception(response.body);
    }

    return MultiSessionRoomMetadata.fromJson(
      (jsonDecode(response.body) as Map).cast<String, dynamic>(),
    );
  }

  Future<void> resolveInviteUri(String uriString) async {
    final invite = parseMultiSessionInviteUri(uriString);
    if (invite == null) return;

    state = state.copyWith(pendingInvite: invite, clearError: true);

    try {
      final metadata = await _fetchRoomMetadata(
        invite.code,
        relayUrl: invite.relayUrl,
      );
      state = state.copyWith(
        pendingInvite: invite.copyWith(metadata: metadata, clearError: true),
      );
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      state = state.copyWith(
        pendingInvite: invite.copyWith(error: _friendlyError(e)),
      );
    }
  }

  void clearPendingInvite() {
    state = state.copyWith(clearInvite: true);
  }

  Future<void> createRoom() async {
    _debugTrace('createRoom:start');
    final relayConfigurationError = _relayConfigurationError();
    if (relayConfigurationError != null) {
      _debugTrace('createRoom:config-error');
      state = state.copyWith(connecting: false, error: relayConfigurationError);
      return;
    }

    state = state.copyWith(connecting: true, clearError: true);
    try {
      final res = await http.post(
        _relayUri("/rooms"),
        headers: {"content-type": "application/json"},
        body: jsonEncode(await _participantPayload()),
      );
      if (res.statusCode >= 400) throw Exception(res.body);
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      state = state.copyWith(
        roomId: json["roomId"] as String,
        code: json["code"] as String,
        token: json["token"] as String,
        memberId: json["memberId"] as String,
        connecting: false,
      );
      _debugTrace('createRoom:created:${state.code}');
      await _connect();
      sendQueue();
      sendPlayback();
    } catch (e, stack) {
      _debugTrace('createRoom:error:$e');
      AppLogger.reportError(e, stack);
      state = state.copyWith(
        connecting: false,
        error: _friendlyError(e),
      );
    }
  }

  Future<void> joinRoom(String code, {String? relayUrl}) async {
    _debugTrace('joinRoom:start:${code.trim().toUpperCase()}');
    final normalizedCode = code.trim().toUpperCase();
    final relayConfigurationError = _relayConfigurationError(relayUrl);
    if (relayConfigurationError != null) {
      _debugTrace('joinRoom:config-error');
      state = state.copyWith(connecting: false, error: relayConfigurationError);
      return;
    }

    final normalizedRelayUrl =
        relayUrl == null ? null : normalizeRelayUrl(relayUrl);

    if (normalizedRelayUrl != null && normalizedRelayUrl.isNotEmpty) {
      ref
          .read(userPreferencesProvider.notifier)
          .setMultiSessionRelayUrl(normalizedRelayUrl);
    }

    state = state.copyWith(connecting: true, clearError: true);
    try {
      final res = await http.post(
        _relayUri("/rooms/$normalizedCode/join", relayUrl: normalizedRelayUrl),
        headers: {"content-type": "application/json"},
        body: jsonEncode(await _participantPayload()),
      );
      if (res.statusCode >= 400) throw Exception(res.body);
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      state = state.copyWith(
        roomId: json["roomId"] as String,
        code: json["code"] as String,
        token: json["token"] as String,
        memberId: json["memberId"] as String,
        connecting: false,
      );
      _debugTrace('joinRoom:joined:${state.code}');
      await _connect();
    } catch (e, stack) {
      _debugTrace('joinRoom:error:$e');
      AppLogger.reportError(e, stack);
      state = state.copyWith(
        connecting: false,
        error: _friendlyError(e),
      );
    }
  }

  Future<void> acceptPendingInvite({bool leaveCurrentRoom = false}) async {
    final invite = state.pendingInvite;
    if (invite == null) return;

    if (leaveCurrentRoom && state.code != null) {
      await leaveRoom();
    }

    await joinRoom(invite.code, relayUrl: invite.relayUrl);
    state = state.copyWith(clearInvite: true);
  }

  Future<void> _connect() async {
    _debugTrace(
      'connect:start code=${state.code} gen=${_connectionGeneration + 1}',
    );
    final relayConfigurationError = _relayConfigurationError();
    if (relayConfigurationError != null) {
      _debugTrace('connect:config-error');
      state = state.copyWith(connected: false, error: relayConfigurationError);
      return;
    }

    _reconnectTimer?.cancel();
    _closingRoom = false;
    _intentionalDisconnect = false;
    await _subscription?.cancel();
    await _channel?.sink.close(status.goingAway);

    final roomCode = state.code;
    final token = state.token;
    if (roomCode == null || token == null) return;

    final relayScheme = Uri.parse(_relayUrl).scheme;
    final uri = _relayUri("/rooms/$roomCode/ws").replace(
      scheme: relayScheme == "https" ? "wss" : "ws",
      queryParameters: {"token": token},
    );

    final generation = ++_connectionGeneration;
    _channel = WebSocketChannel.connect(uri);
    await _channel!.ready;
    _debugTrace('connect:ready code=$roomCode gen=$generation');
    _subscription = _channel!.stream.listen(
      (message) => _handleMessage(generation, message),
      onError: (error, stack) {
        if (generation != _connectionGeneration) return;
        _debugTrace('connect:onError gen=$generation error=$error');
        AppLogger.reportError(error, stack);
        state = state.copyWith(
          connected: false,
          error: _friendlyError(error),
        );
        if (_intentionalDisconnect) return;
        _scheduleReconnect();
      },
      onDone: () {
        if (generation != _connectionGeneration) return;
        _debugTrace(
          'connect:onDone gen=$generation closing=$_closingRoom intentional=$_intentionalDisconnect',
        );
        state = state.copyWith(connected: false);
        if (_intentionalDisconnect) return;
        _scheduleReconnect();
      },
    );
    state = state.copyWith(connected: true);
    _debugTrace('connect:connected code=$roomCode gen=$generation');
  }

  void _scheduleReconnect() {
    if (_closingRoom ||
        _intentionalDisconnect ||
        state.code == null ||
        state.token == null) {
      return;
    }
    _reconnectTimer?.cancel();
    _debugTrace('reconnect:scheduled code=${state.code}');
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      _debugTrace('reconnect:fire code=${state.code}');
      _connect();
    });
  }

  Future<void> _handleMessage(int generation, dynamic message) async {
    if (generation != _connectionGeneration) return;
    if (_closingRoom || _intentionalDisconnect) return;

    final event = jsonDecode(message as String) as Map<String, dynamic>;
    _debugTrace(
        'message:type=${event["type"]} gen=$generation code=${state.code}');
    if (event["type"] == "ended") {
      unawaited(
        _beginRoomShutdown(notifyRelay: false, endedByHost: true),
      );
      state = const MultiSessionState(error: "Room ended");
      return;
    }

    if (event["type"] != "snapshot") return;

    final snapshot = MultiSessionRoomSnapshot.fromJson(
      (event["data"] as Map).cast<String, dynamic>(),
    );
    if ((state.snapshot?.sequence ?? -1) > snapshot.sequence) return;

    final previousSnapshot = state.snapshot;
    final isPlaybackOnlyUpdate = previousSnapshot != null &&
        _isPlaybackOnlySnapshotUpdate(previousSnapshot, snapshot);

    if (!isPlaybackOnlyUpdate || state.code != snapshot.code) {
      state = state.copyWith(snapshot: snapshot, code: snapshot.code);
    }
    await _applySnapshot(snapshot);
  }

  Future<void> _applySnapshot(MultiSessionRoomSnapshot snapshot) async {
    if (_closingRoom || _intentionalDisconnect) return;
    if (_applyingRemote) return;

    _debugTrace(
      'snapshot:apply seq=${snapshot.sequence} queue=${snapshot.queue.length} code=${snapshot.code}',
    );
    _applyingRemote = true;
    try {
      final localState = ref.read(audioPlayerProvider);
      final localTracks =
          localState.tracks.whereType<SpotubeFullTrackObject>().toList();
      final remoteTrackIds = _queueIds(snapshot.queue);
      final isMyQueue = snapshot.lastQueueUpdateBy == session.memberId;

      if (remoteTrackIds.isEmpty && !isMyQueue) {
        if (localTracks.isNotEmpty) {
          await ref.read(audioPlayerProvider.notifier).load(
                const [],
                autoPlay: false,
              );
        }
        return;
      }

      final localTrackIds =
          localTracks.map((track) => track.id).toList(growable: false);

      final targetIndex = isMyQueue
          ? localTrackIds.indexOf(snapshot.activeTrackId ?? "")
          : remoteTrackIds.indexOf(snapshot.activeTrackId ?? "");
      final activeIndex = snapshot.activeTrackId == null ? 0 : targetIndex;

      final index = activeIndex < 0 ? 0 : activeIndex;
      final activeTrackChanged =
          localState.activeTrack?.id != snapshot.activeTrackId;
          
      if (snapshot.activeTrackId != null &&
          _failedSessionTracks.contains(snapshot.activeTrackId)) {
        if (audioPlayer.isPlaying) {
          await audioPlayer.pause();
        }
        return;
      }

      final queueIdsChanged =
          !isMyQueue && !_stringListEquality.equals(localTrackIds, remoteTrackIds);
      final indexChanged = localState.currentIndex != index;

      if (queueIdsChanged) {
        final tracks = snapshot.queue
            .map(SpotubeTrackObject.fromJson)
            .whereType<SpotubeFullTrackObject>()
            .toList();
        if (tracks.isEmpty) return;

        await ref.read(audioPlayerProvider.notifier).load(
              tracks,
              initialIndex: index,
              autoPlay: snapshot.playing,
            );
      } else if (indexChanged) {
        final medias = audioPlayer.playlist.medias;
        if (medias.isNotEmpty && index < medias.length) {
          await audioPlayer.openPlaylist(
            medias,
            initialIndex: index,
            autoPlay: snapshot.playing,
          );
        }
      }

      final postLoadState = ref.read(audioPlayerProvider);
      final activeTrack = postLoadState.activeTrack;
      final activeSource = snapshot.activeSource;
      if (activeTrack is SpotubeFullTrackObject &&
          activeSource != null &&
          activeTrack.id == snapshot.activeTrackId) {
        final sourcedTrack =
            await ref.read(sourcedTrackProvider(activeTrack).future);
        if (sourcedTrack.info.id != activeSource.id) {
          final swapped = await ref
              .read(sourcedTrackProvider(activeTrack).notifier)
              .swapWithSibling(activeSource);
          if (swapped.info.id == activeSource.id) {
            await ref.read(audioPlayerProvider.notifier).swapActiveSource();
          }
        }
      }

      final localPositionMs = audioPlayer.position.inMilliseconds;
      final positionDriftMs = (snapshot.positionMs - localPositionMs).abs();
      final shouldSeek = queueIdsChanged ||
          indexChanged ||
          activeTrackChanged ||
          localPositionMs == 0 ||
          positionDriftMs >= _remoteSeekThresholdMs;

      if (shouldSeek) {
        await audioPlayer.seek(Duration(milliseconds: snapshot.positionMs));
      }
      _rememberObservedPosition(Duration(milliseconds: snapshot.positionMs));
      if (snapshot.playing && !audioPlayer.isPlaying) {
        await audioPlayer.resume();
      } else if (!snapshot.playing && audioPlayer.isPlaying) {
        await audioPlayer.pause();
      }

      if (audioPlayer.loopMode.name != snapshot.loopMode) {
        await audioPlayer.setLoopMode(
          PlaylistMode.values.firstWhere(
            (mode) => mode.name == snapshot.loopMode,
            orElse: () => PlaylistMode.none,
          ),
        );
      }
      if (audioPlayer.isShuffled != snapshot.shuffle) {
        await audioPlayer.setShuffle(snapshot.shuffle);
      }
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
    } finally {
      _applyingRemote = false;
    }
  }

  void _send(String type, Object? data) {
    if (_closingRoom || !state.connected) return;
    _channel?.sink.add(encodeRoomEvent(type, data));
  }

  void _disposeConnection() {
    _debugTrace('dispose:start gen=$_connectionGeneration code=${state.code}');
    _connectionGeneration++;
    final subscription = _subscription;
    final channel = _channel;

    _subscription = null;
    _channel = null;

    if (subscription != null) {
      unawaited(
        subscription.cancel().catchError((error, stackTrace) {
          return AppLogger.reportError(
            error,
            stackTrace,
            "Failed to cancel multi-session subscription",
          );
        }),
      );
    }

    if (channel != null) {
      unawaited(
        channel.sink.close(status.goingAway).catchError((error, stackTrace) {
          return AppLogger.reportError(
            error,
            stackTrace,
            "Failed to close multi-session connection",
          );
        }),
      );
    }
    _debugTrace('dispose:queued gen=$_connectionGeneration');
  }

  Future<void> _beginRoomShutdown({
    required bool notifyRelay,
    required bool endedByHost,
  }) async {
    if (_closingRoom) {
      _debugTrace('shutdown:ignored already-closing');
      return;
    }

    _debugTrace(
      'shutdown:start notifyRelay=$notifyRelay endedByHost=$endedByHost code=${state.code}',
    );
    _reconnectTimer?.cancel();
    _closingRoom = true;
    _intentionalDisconnect = true;
    final previousState = state;
    state = endedByHost
        ? const MultiSessionState(error: "Room ended")
        : state.copyWith(clearRoom: true);

    try {
      if (notifyRelay && previousState.connected) {
        final eventType = previousState.isHost ? "end" : "leave";
        _debugTrace('shutdown:send:$eventType');
        _channel?.sink.add(encodeRoomEvent(eventType, null));
        if (previousState.isHost) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    } catch (error, stackTrace) {
      await AppLogger.reportError(
        error,
        stackTrace,
        previousState.isHost
            ? "Failed to notify relay about ending a multi-session room"
            : "Failed to notify relay about leaving a multi-session room",
      );
    } finally {
      _disposeConnection();
      _debugTrace('shutdown:end');
    }
  }

  void sendQueue() {
    unawaited(() async {
      final playerState = ref.read(audioPlayerProvider);
      final tracks =
          playerState.tracks.whereType<SpotubeFullTrackObject>().toList();
      final activeIndex = playerState.currentIndex;

      final start = math.max(0, activeIndex - 10);
      final end = math.min(tracks.length, start + 100);
      final slicedTracks = tracks.sublist(start, end);

      _send("queue", {
        "queue": slicedTracks.map((track) => track.toJson()).toList(),
        "activeTrackId": playerState.activeTrack?.id,
        "activeSource": await _activeSourcePayload(),
        "positionMs": audioPlayer.position.inMilliseconds,
      });
    }());
  }

  void sendPlayback() async {
    _send("playback", {
      "playing": audioPlayer.isPlaying,
      "positionMs": audioPlayer.position.inMilliseconds,
      "activeTrackId": ref.read(audioPlayerProvider).activeTrack?.id,
      "activeSource": await _activeSourcePayload(),
      "loopMode": audioPlayer.loopMode.name,
      "shuffle": audioPlayer.isShuffled,
    });
  }

  void setMemberPreset(String memberId, MultiSessionMemberPreset preset) {
    if (!_guardPermission(
      MultiSessionPermission.manageMembers,
      "change member roles",
    )) {
      return;
    }
    final memberName = _memberById(memberId)?.name ?? "That member";
    _pushNotice("$memberName is now ${preset.label} by $_actorName");
    _send("permissions", {
      "memberId": memberId,
      "preset": preset.name,
    });
  }

  void setMemberPermissions(
    String memberId,
    Map<MultiSessionPermission, bool> permissions,
  ) {
    if (!_guardPermission(
      MultiSessionPermission.manageMembers,
      "change member permissions",
    )) {
      return;
    }
    final memberName = _memberById(memberId)?.name ?? "That member";
    _pushNotice("Permissions updated for $memberName by $_actorName");
    _send("permissions", {
      "memberId": memberId,
      "permissions": {
        for (final MapEntry(:key, :value) in permissions.entries)
          key.name: value,
      },
    });
  }

  void kickMember(String memberId) {
    if (!_guardPermission(
      MultiSessionPermission.manageMembers,
      "kick a member",
    )) {
      return;
    }
    final memberName = _memberById(memberId)?.name ?? "That member";
    _pushNotice("$memberName was kicked by $_actorName");
    _send("kick", {"memberId": memberId});
  }

  void setCommunityQueueEnabled(bool enabled) {
    if (!_guardPermission(
      MultiSessionPermission.editQueue,
      "edit the queue",
    )) {
      return;
    }
    _pushNotice(
      "Community queue ${enabled ? "enabled" : "disabled"} by $_actorName",
    );
    _send("communityQueue", {"enabled": enabled});
  }

  void suggestTrack(SpotubeFullTrackObject track) {
    if (!_guardPermission(
      MultiSessionPermission.suggestTracks,
      "suggest tracks",
    )) {
      return;
    }
    _pushNotice("${track.name} suggested by $_actorName");
    _send("suggestion:add", {"track": track.toJson()});
  }

  void voteSuggestion(String suggestionId) {
    if (!_guardPermission(
      MultiSessionPermission.voteTracks,
      "vote on suggestions",
    )) {
      return;
    }
    _pushNotice("Suggestion upvoted by $_actorName");
    _send("suggestion:vote", {"suggestionId": suggestionId});
  }

  void removeSuggestion(String suggestionId) {
    if (!_guardPermission(
      MultiSessionPermission.editQueue,
      "remove suggestions",
    )) {
      return;
    }
    _pushNotice("Suggestion removed by $_actorName");
    _send("suggestion:remove", {"suggestionId": suggestionId});
  }

  void promoteSuggestion(String suggestionId) {
    if (!_guardPermission(
      MultiSessionPermission.editQueue,
      "promote suggestions",
    )) {
      return;
    }
    _pushNotice("Suggestion promoted by $_actorName");
    _send("suggestion:promote", {"suggestionId": suggestionId});
  }

  Future<void> shutdownForAppClose() async {
    if (!state.connected || state.code == null) return;

    try {
      if (state.isHost) {
        await endRoom().timeout(const Duration(seconds: 1));
      } else {
        await leaveRoom().timeout(const Duration(seconds: 1));
      }
    } catch (error, stackTrace) {
      await AppLogger.reportError(
        error,
        stackTrace,
        "Failed to close multi-session room during app shutdown",
      );
    }
  }

  Future<void> leaveRoom() async {
    await _beginRoomShutdown(notifyRelay: true, endedByHost: false);
  }

  Future<void> endRoom() async {
    if (!state.isHost) {
      await leaveRoom();
      return;
    }
    await _beginRoomShutdown(notifyRelay: true, endedByHost: true);
  }
}

final multiSessionProvider =
    NotifierProvider<MultiSessionNotifier, MultiSessionState>(
  () => MultiSessionNotifier(),
);
