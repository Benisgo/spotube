import 'dart:async';
import 'dart:convert';

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
import 'package:spotube/services/kv_store/kv_store.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

class MultiSessionNotifier extends Notifier<MultiSessionState> {
  static const _legacyRelayUrl = "https://spotube-multi-session.workers.dev";
  static const _remoteSeekThresholdMs = 4000;
  static const _stringListEquality = ListEquality<String>();

  /// After a local seek/play, ignore remote position-only snapshots for this
  /// long so a stale echo/tick can't rewind us (rubber-banding).
  static const _localActionGraceMs = 2000;

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
  String? _lastObservedTrackId;
  double? _preMuteVolume;

  /// Tracks tracks that failed to load, mapped to when they failed.
  /// Entries older than 30s are evicted before checking (Bug C1).
  final Map<String, DateTime> _failedSessionTracks = {};

  /// Cooldown timestamp: don't pause on errors more than once per 3s (Bug C3).
  DateTime? _lastErrorPauseAt;
  Timer? _errorRetryTimer;
  Timer? _sendQueueTimer;
  MultiSessionRoomSnapshot? _pendingSnapshot;
  MultiSessionRoomSnapshot? _lastAppliedSnapshot;
  bool _snapshotPumpRunning = false;
  int? _lastSentPositionMs;
  DateTime? _lastSentPositionAt;
  DateTime? _appliedSnapshotAt;

  /// When the local user last performed a seek/play/pause/queue action.
  DateTime? _lastLocalActionAt;

  /// True when this client created the room (i.e. is the host), even before
  /// the first snapshot arrives (state.isHost needs snapshot.members).
  bool _isCreatorHost = false;

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
      (!_applyingRemote || state.can(MultiSessionPermission.controlPlayback)) &&
      state.can(MultiSessionPermission.controlPlayback);

  /// Non-hosts must not push their (possibly unsynced/zeroed) local state to
  /// the room before applying at least one snapshot. A fresh joiner or a
  /// newly-empowered member would otherwise reset the room's playback/queue
  /// to their own (wrong) position — the "song restarts at 00:00 on join or
  /// permission change" bug.
  bool get _canSendRoomState =>
      state.connected && (_isCreatorHost || _lastAppliedSnapshot != null);

  bool get _canEditQueue =>
      state.connected &&
      (!_applyingRemote || state.can(MultiSessionPermission.editQueue)) &&
      state.can(MultiSessionPermission.editQueue);

  bool get _shouldSuppressOutboundSync =>
      _appliedSnapshotAt != null &&
      DateTime.now().difference(_appliedSnapshotAt!).inMilliseconds < 500;

  Future<void> _syncLocalMuteState() async {
    final shouldMute = state.locallyMuted;

    if (shouldMute) {
      _preMuteVolume ??= audioPlayer.volume > 0 ? audioPlayer.volume : null;
      if (audioPlayer.volume > 0) {
        await audioPlayer.setVolume(0);
      }
      return;
    }

    final restoreVolume = _preMuteVolume ?? KVStoreService.volume;
    _preMuteVolume = null;
    if ((audioPlayer.volume - restoreVolume).abs() > 0.001) {
      await audioPlayer.setVolume(restoreVolume);
    }
  }

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
        previous.autoAcceptSuggestedTracks == next.autoAcceptSuggestedTracks &&
        previous.discordJoinEnabled == next.discordJoinEnabled &&
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

  bool _isTrivialPositionTick(
    MultiSessionRoomSnapshot previous,
    MultiSessionRoomSnapshot next,
  ) {
    return _isPlaybackOnlySnapshotUpdate(previous, next) &&
        previous.playing == next.playing &&
        previous.loopMode == next.loopMode &&
        previous.shuffle == next.shuffle &&
        previous.activeSource?.id == next.activeSource?.id;
  }

  bool _canSkipTrivialSnapshotApply(MultiSessionRoomSnapshot snapshot) {
    final localState = ref.read(audioPlayerProvider);
    final localActiveTrackId = localState.activeTrack?.id;
    final activeTrackId = snapshot.activeTrackId;
    if (localActiveTrackId != activeTrackId) return false;

    final localTrackIds =
        localState.tracks.map((track) => track.id).toList(growable: false);
    final remoteTrackIds = _queueIds(snapshot.queue);
    if (!_stringListEquality.equals(localTrackIds, remoteTrackIds)) {
      return false;
    }

    final targetIndex =
        activeTrackId == null ? 0 : remoteTrackIds.indexOf(activeTrackId);
    final index = targetIndex < 0 ? 0 : targetIndex;
    if (localState.currentIndex != index) return false;

    if (audioPlayer.isPlaying != snapshot.playing) return false;
    if (audioPlayer.loopMode.name != snapshot.loopMode) return false;
    if (audioPlayer.isShuffled != snapshot.shuffle) return false;

    final lastApplied = _lastAppliedSnapshot;
    if (lastApplied?.activeTrackId != activeTrackId ||
        lastApplied?.activeSource?.id != snapshot.activeSource?.id) {
      return false;
    }

    final localPositionMs = audioPlayer.position.inMilliseconds;
    final driftMs = (snapshot.positionMs - localPositionMs).abs();
    return driftMs < _remoteSeekThresholdMs;
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
    listenSelf((previous, next) {
      audioPlayer.setSuppressCompletedAdvanceRecovery(
        next.connected && !next.can(MultiSessionPermission.controlPlayback),
      );
      if (previous?.locallyMuted != next.locallyMuted) {
        unawaited(_syncLocalMuteState());
      }
    });

    ref.listen(audioPlayerProvider, (previous, next) {
      if (!_canEditQueue) return;
      // Never re-broadcast changes that we ourselves caused while applying a
      // snapshot (e.g. the jumpTo for a remote skip). Those flow back through
      // the playlist/index streams mid-apply and would otherwise echo as if
      // they were our own action.
      if (_applyingRemote) return;

      final previousIds = previous?.tracks.map((track) => track.id).join(",");
      final nextIds = next.tracks.map((track) => track.id).join(",");
      if (previousIds != nextIds ||
          previous?.currentIndex != next.currentIndex) {
        final localTrackIds =
            next.tracks.map((track) => track.id).toList(growable: false);
        // Compare against the snapshot we actually APPLIED (not the newest
        // state.snapshot, which can be a newer trivial tick), so a queue that
        // still matches our applied queue is recognized as a sync echo.
        final syncSnapshot = _lastAppliedSnapshot ?? state.snapshot;
        final remoteTrackIds = _queueIds(syncSnapshot?.queue ?? const []);
        final activeIndex = syncSnapshot?.activeTrackId == null
            ? 0
            : remoteTrackIds.indexOf(syncSnapshot!.activeTrackId!);
        final index = activeIndex < 0 ? 0 : activeIndex;

        final isSnapshotSync =
            _stringListEquality.equals(localTrackIds, remoteTrackIds) &&
                next.currentIndex == index;

        if (isSnapshotSync) return;

        // Genuine local queue change (play/load/edit), not a snapshot sync.
        if (!_applyingRemote) _lastLocalActionAt = DateTime.now();

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
        if (previousIds == nextIds &&
            previous?.currentIndex != next.currentIndex) {
          // Track advance (or jumpTo) with the SAME queue: broadcast the new
          // active track via a playback update, which updates activeTrackId /
          // position WITHOUT replacing the room's queue list. A full queue
          // push here would clobber other members' edits (e.g. a co-host's
          // "Play Next" / add that this member hasn't loaded yet).
          sendPlayback(bypassSuppress: true);
        } else {
          // Structural queue change (add/remove/reorder/load): debounce the
          // full queue push to avoid re-serializing large queues on every
          // track advance (e.g., 3000-song playlist).
          _sendQueueTimer?.cancel();
          _sendQueueTimer = Timer(const Duration(milliseconds: 200), sendQueue);
        }
      }
    });

    final playingSubscription = audioPlayer.playingStream.listen((playing) {
      if (!_canControlPlayback) return;
      // A playing/pause event triggered while we were applying a snapshot is
      // our own echo of that apply (resume/pause toward the snapshot state) —
      // never re-broadcast it.
      if (_applyingRemote) return;
      // A late media_kit event right after an apply that matches the applied
      // state is also an echo.
      if (_shouldSuppressOutboundSync &&
          _lastAppliedSnapshot?.playing == playing) {
        return;
      }
      // Genuine local play/pause (user action, or the host's completed-advance
      // recovery resuming after a track ended). Always broadcast it, even
      // within the post-apply suppression window — otherwise the "next song
      // plays but stays paused" bug happens.
      _lastLocalActionAt = DateTime.now();
      // Don't toast for the transient pause/resume that accompanies a natural
      // track change (mpv pauses at the boundary, then the completed-advance
      // recovery resumes). Only notice genuine user toggles.
      final duration = audioPlayer.duration;
      final position = audioPlayer.position;
      final atTrackBoundary = duration > Duration.zero &&
          (position >= (duration - const Duration(seconds: 2)) ||
              position <= const Duration(seconds: 1));
      if (!atTrackBoundary) {
        _pushNotice(
          playing
              ? "Playback resumed by $_actorName"
              : "Playback paused by $_actorName",
        );
      }
      _rememberObservedPosition(audioPlayer.position);
      sendPlayback(bypassSuppress: true);
    });

    final positionSubscription = audioPlayer.positionStream.listen((position) {
      if (!state.connected) return;
      final now = DateTime.now();
      final previousPositionMs = _lastObservedPositionMs;
      final previousObservedAt = _lastObservedAt;
      _rememberObservedPosition(position);

      // When the active track changed (natural end / skip), sendQueue already
      // broadcasts the new track + position. Don't fire a non-passive playback
      // send here: it could carry a stale playing=false captured during the
      // track transition and broadcast a false "paused" to the whole room.
      final currentTrackId = ref.read(audioPlayerProvider).activeTrack?.id;
      final trackChanged = currentTrackId != _lastObservedTrackId;
      _lastObservedTrackId = currentTrackId;
      if (trackChanged) return;

      if (!_canControlPlayback ||
          previousPositionMs == null ||
          previousObservedAt == null) {
        return;
      }

      if (_shouldSuppressOutboundSync) return;

      final elapsedMs = now.difference(previousObservedAt).inMilliseconds;
      final expectedPositionMs =
          previousPositionMs + (audioPlayer.isPlaying ? elapsedMs : 0);

      if ((position.inMilliseconds - expectedPositionMs).abs() > 1500) {
        // Genuine local seek/position jump (not one we applied from a snapshot).
        if (!_applyingRemote) _lastLocalActionAt = DateTime.now();
        sendPlayback();
      }
    });

    final errorSubscription = audioPlayer.errorStream.listen((error) {
      if (!state.connected || _canControlPlayback) return;

      // Error cooldown: don't pause more than once per 3s (Bug C3)
      final now = DateTime.now();
      if (_lastErrorPauseAt != null &&
          now.difference(_lastErrorPauseAt!).inMilliseconds < 3000) {
        return;
      }

      final playerState = ref.read(audioPlayerProvider);
      final currentTrackId = playerState.activeTrack?.id;
      if (currentTrackId != null) {
        _failedSessionTracks[currentTrackId] = now;
        _lastErrorPauseAt = now;
        _pushNotice("Track failed to load - playback paused",
            destructive: true);
      }
      if (audioPlayer.isPlaying) {
        audioPlayer.pause();
      }

      // Schedule retry in 3s (Bug C1): clear this track from failed set
      // and resume if the snapshot still points to it.
      _errorRetryTimer?.cancel();
      final retryTrackId = currentTrackId;
      _errorRetryTimer = Timer(const Duration(seconds: 3), () async {
        if (_closingRoom || _intentionalDisconnect || retryTrackId == null)
          return;
        _failedSessionTracks.remove(retryTrackId);
        // If the snapshot still points to this track, resume playback
        final snapshot = state.snapshot;
        if (snapshot != null &&
            snapshot.activeTrackId == retryTrackId &&
            snapshot.playing &&
            !state.locallyPaused) {
          await audioPlayer.resume();
        }
      });
    });

    _positionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!state.connected || !state.isHost) return;
      if (!_canControlPlayback) return;
      if (_shouldSuppressOutboundSync) return;
      _rememberObservedPosition(audioPlayer.position);
      // Passive, position-only sync: never carries the active track/source,
      // so it can't revert a newer track change on other members, and the
      // relay won't let it clobber a recent active seek.
      sendPlayback(passive: true);
    });

    ref.onDispose(() {
      playingSubscription.cancel();
      positionSubscription.cancel();
      errorSubscription.cancel();
      _positionTimer?.cancel();
      _reconnectTimer?.cancel();
      _errorRetryTimer?.cancel();
      _sendQueueTimer?.cancel();
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
      _isCreatorHost = true;
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
    _isCreatorHost = false;
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

    _positionTimer?.cancel();
    _reconnectTimer?.cancel();
    _closingRoom = false;
    _intentionalDisconnect = false;
    _pendingSnapshot = null;
    _lastAppliedSnapshot = null;
    _lastSentPositionMs = null;
    _lastSentPositionAt = null;
    _lastObservedPositionMs = null;
    _lastObservedAt = null;
    _lastObservedTrackId = null;
    _lastLocalActionAt = null;
    _failedSessionTracks.clear();
    _lastErrorPauseAt = null;
    _errorRetryTimer?.cancel();
    _snapshotPumpRunning = false;
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
    final isTrivialPositionTick = previousSnapshot != null &&
        _isTrivialPositionTick(previousSnapshot, snapshot);
    final playbackStateChanged = previousSnapshot != null &&
        (previousSnapshot.playing != snapshot.playing ||
            previousSnapshot.loopMode != snapshot.loopMode ||
            previousSnapshot.shuffle != snapshot.shuffle);

    if (!isPlaybackOnlyUpdate ||
        state.code != snapshot.code ||
        playbackStateChanged) {
      state = state.copyWith(snapshot: snapshot, code: snapshot.code);
    }

    // Don't skip trivial ticks while a snapshot is being applied
    // to avoid reading stale player state mid-apply.
    if (!_applyingRemote &&
        isTrivialPositionTick &&
        _canSkipTrivialSnapshotApply(snapshot)) {
      _lastAppliedSnapshot = snapshot;
      _rememberObservedPosition(audioPlayer.position);
      return;
    }

    _queueSnapshotApply(snapshot);
  }

  void _queueSnapshotApply(MultiSessionRoomSnapshot snapshot) {
    if ((_pendingSnapshot?.sequence ?? -1) < snapshot.sequence) {
      _pendingSnapshot = snapshot;
    }

    if (_snapshotPumpRunning) return;

    _snapshotPumpRunning = true;
    unawaited(_drainSnapshotQueue());
  }

  Future<void> _drainSnapshotQueue() async {
    try {
      while (true) {
        final snapshot = _pendingSnapshot;
        _pendingSnapshot = null;
        if (snapshot == null) break;
        await _applySnapshot(snapshot);
      }
    } finally {
      _snapshotPumpRunning = false;
      if (_pendingSnapshot != null &&
          !_closingRoom &&
          !_intentionalDisconnect &&
          !_snapshotPumpRunning) {
        _snapshotPumpRunning = true;
        unawaited(_drainSnapshotQueue());
      }
    }
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
      final isMyQueue = snapshot.lastQueueUpdateBy == state.memberId;

      // Don't treat this snapshot as remote if it reflects OUR OWN last send
      // (the relay attributes it via lastPlaybackUpdateBy). Fall back to the
      // old proximity heuristic only when the relay doesn't provide
      // attribution (older worker). Computed early so a stale own-echo (e.g.
      // our own "paused" send arriving after our player already advanced to
      // the next track) can't make us jump back to a track we've left — the
      // "host replays the ended track" variant of the natural-end bug.
      final isOurOwnEcho = snapshot.lastPlaybackUpdateBy != null
          ? snapshot.lastPlaybackUpdateBy == state.memberId
          : _lastSentPositionMs != null &&
              _lastSentPositionAt != null &&
              (snapshot.positionMs - _lastSentPositionMs!).abs() <
                  _remoteSeekThresholdMs &&
              DateTime.now().difference(_lastSentPositionAt!).inMilliseconds <
                  1500;

      // We just performed a local seek/play/pause/queue action. For a short
      // grace window, suppress REMOTE position-only updates so a stale echo
      // or the host's 1s position tick (captured before our action reached
      // the relay) can't rewind us.
      final recentlyActedLocally = _lastLocalActionAt != null &&
          DateTime.now().difference(_lastLocalActionAt!).inMilliseconds <
              _localActionGraceMs;

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

      // Resolve the active track's index from OUR local queue when possible
      // (correct even when the room queue is a windowed/truncated slice),
      // falling back to the room queue for fresh joiners who haven't loaded.
      // Never let an unresolved track collapse to index 0 — that made the
      // song jump/restart at 00:00 on join/permission changes.
      final localIndex = localTrackIds.indexOf(snapshot.activeTrackId ?? "");
      final remoteIndex = remoteTrackIds.indexOf(snapshot.activeTrackId ?? "");
      final activeIndex = snapshot.activeTrackId == null
          ? 0
          : (localIndex >= 0 ? localIndex : remoteIndex);

      final index = activeIndex < 0 ? localState.currentIndex : activeIndex;
      final activeTrackChanged =
          localState.activeTrack?.id != snapshot.activeTrackId;

      if (activeTrackChanged) {
        // Clear ALL failed tracks including the new active one.
        // The old inverted logic kept the new track in the set.
        _failedSessionTracks.clear();
        _lastErrorPauseAt = null;
      }

      // Evict failed tracks older than 30s (Bug C1)
      _failedSessionTracks.removeWhere(
        (_, failedAt) =>
            DateTime.now().difference(failedAt).inMilliseconds > 30000,
      );

      if (snapshot.activeTrackId != null &&
          _failedSessionTracks.containsKey(snapshot.activeTrackId)) {
        if (audioPlayer.isPlaying) {
          await audioPlayer.pause();
        }
        return;
      }

      final queueIdsChanged = !isMyQueue &&
          !_stringListEquality.equals(localTrackIds, remoteTrackIds);
      final indexChanged = localState.currentIndex != index;
      final shouldSyncActiveSource = queueIdsChanged ||
          indexChanged ||
          activeTrackChanged ||
          _lastAppliedSnapshot?.activeTrackId != snapshot.activeTrackId ||
          _lastAppliedSnapshot?.activeSource?.id != snapshot.activeSource?.id;

      if (queueIdsChanged && activeTrackChanged) {
        // Full playlist reload: active track changed, need fresh playlist
        // Filter out local tracks (downloaded files) since they can't
        // be played by other members (Bug B2). Keep them in snapshot
        // queue for display but exclude from playback.
        final tracks = snapshot.queue
            .map(SpotubeTrackObject.fromJson)
            .whereType<SpotubeFullTrackObject>()
            .toList();
        if (tracks.isEmpty) return;

        // Only yank playback to the active track if it's actually in the
        // queue we're loading; otherwise leave current playback alone (this
        // prevented songs restarting at 00:00 on join/permission changes).
        final loadIndex = snapshot.activeTrackId == null
            ? index
            : tracks.indexWhere((t) => t.id == snapshot.activeTrackId);
        if (loadIndex < 0) return;

        await ref.read(audioPlayerProvider.notifier).load(
              tracks,
              initialIndex: loadIndex,
              // Respect local pause: don't auto-play if user locally paused
              autoPlay: state.locallyPaused ? false : snapshot.playing,
            );
      } else if (queueIdsChanged && !activeTrackChanged) {
        // Queue modified (add/remove/promote) but current track unchanged.
        // Skip full load to avoid interrupting playback (Bug C2).
        // The promoted/added track will appear when the next snapshot
        // triggers load() on actual track transition.
      } else if (indexChanged && !isOurOwnEcho) {
        // Never jump the player because of our own stale echo (we may have
        // already advanced past the track the echo claims is active).
        final playlistLength = audioPlayer.playlist.medias.length;
        if (playlistLength > 0 && index < playlistLength) {
          await audioPlayer.jumpTo(index);
        }
      }

      final postLoadState = ref.read(audioPlayerProvider);
      final activeTrack = postLoadState.activeTrack;
      final activeSource = snapshot.activeSource;

      // Evict old failures again after load() to catch any that aged out
      // during the async load() call.
      _failedSessionTracks.removeWhere(
        (_, failedAt) =>
            DateTime.now().difference(failedAt).inMilliseconds > 30000,
      );

      // Skip source swap if load() was already called — the new playlist
      // already resolved the correct source. Avoids nested load(). Also
      // skip during the local-action grace window so a stale snapshot can't
      // swap our just-selected source out from under us, and skip while the
      // user is locally paused (swapActiveSource reloads with autoPlay: true
      // and would yank a paused listener back into playback).
      if (!state.locallyPaused &&
          !queueIdsChanged &&
          !recentlyActedLocally &&
          shouldSyncActiveSource &&
          activeTrack is SpotubeFullTrackObject &&
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
      // Only seek when the active track changed (switching to a new track),
      // OR when it's a pure position update with significant drift AND we
      // haven't just acted locally. Skip seeking on queue-only or index-only
      // changes, during the local-action grace window (Bug: seek
      // rubber-banding), and while the user is locally paused (a listener's
      // local pause is a real pause — the progress bar must not crawl).
      final shouldSeek = !isOurOwnEcho &&
          !state.locallyPaused &&
          (activeTrackChanged ||
              (!queueIdsChanged &&
                  !indexChanged &&
                  !recentlyActedLocally &&
                  (localPositionMs == 0 ||
                      positionDriftMs >= _remoteSeekThresholdMs)));

      if (shouldSeek) {
        await audioPlayer.seek(Duration(milliseconds: snapshot.positionMs));
      }
      _rememberObservedPosition(Duration(milliseconds: snapshot.positionMs));

      // Respect local pause: don't override playback if user locally paused.
      // During the local-action grace window, only sync play/pause when the
      // active track or queue actually changed (a real remote action), so a
      // stale snapshot can't undo our just-performed play/pause. Never sync
      // play/pause from our own echo (we know our own playing state).
      final shouldSyncPlayback = !isOurOwnEcho &&
          (!recentlyActedLocally || activeTrackChanged || queueIdsChanged);
      if (!state.locallyPaused && shouldSyncPlayback) {
        if (snapshot.playing && !audioPlayer.isPlaying) {
          await audioPlayer.resume();
        } else if (!snapshot.playing && audioPlayer.isPlaying) {
          await audioPlayer.pause();
        }
      }

      if (audioPlayer.loopMode.name != snapshot.loopMode) {
        await audioPlayer.setLoopMode(
          PlaylistMode.values.firstWhere(
            (mode) => mode.name == snapshot.loopMode,
            orElse: () => PlaylistMode.none,
          ),
        );
      }
      // For non-host members, force shuffle OFF — the queue snapshot
      // order is the source of truth. media_kit's shuffled index
      // mapping would desync non-host playback (Bug B1).
      final targetShuffle = state.isHost ? snapshot.shuffle : false;
      if (audioPlayer.isShuffled != targetShuffle) {
        await audioPlayer.setShuffle(targetShuffle);
      }
      _lastAppliedSnapshot = snapshot;
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
    } finally {
      _appliedSnapshotAt = DateTime.now();
      _applyingRemote = false;
    }
  }

  void _send(String type, Object? data) {
    if (_closingRoom || !state.connected) return;
    _channel?.sink.add(encodeRoomEvent(type, data));
  }

  Future<void> setLocalPlaybackPaused(bool paused) async {
    if (!state.connected || state.can(MultiSessionPermission.controlPlayback)) {
      return;
    }

    state = state.copyWith(locallyPaused: paused);
    if (paused) {
      // Actually pause the local player (not just mute) so a listener's
      // Pause button behaves like a real pause. Snapshots never resume us
      // while locallyPaused is set, so the pause persists across the room's
      // position ticks. Call pause() unconditionally (it is idempotent): a
      // stale audioPlayer.isPlaying must not let a mid-apply snapshot skip
      // the listener's pause.
      await audioPlayer.pause();
    } else {
      // Resume and catch up to the room's authoritative position, so the
      // listener rejoins the live playback instead of resuming from where
      // they paused (which could be minutes behind).
      final snapshot = state.snapshot;
      if (snapshot != null && snapshot.playing) {
        if (!audioPlayer.isPlaying) {
          await audioPlayer.resume();
        }
        final driftMs =
            (snapshot.positionMs - audioPlayer.position.inMilliseconds).abs();
        if (driftMs >= _remoteSeekThresholdMs) {
          await audioPlayer.seek(Duration(milliseconds: snapshot.positionMs));
        }
      }
    }
  }

  Future<void> toggleLocalPlaybackPaused() async {
    await setLocalPlaybackPaused(!state.locallyPaused);
  }

  Future<void> setPreviewSilenced(bool silenced) async {
    state = state.copyWith(previewSilenced: silenced);
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
    _positionTimer?.cancel();
    _reconnectTimer?.cancel();
    _closingRoom = true;
    _intentionalDisconnect = true;
    _isCreatorHost = false;
    _pendingSnapshot = null;
    _lastAppliedSnapshot = null;
    _snapshotPumpRunning = false;
    _errorRetryTimer?.cancel();
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
      if (!_canSendRoomState) return;
      final playerState = ref.read(audioPlayerProvider);
      // Echo guard: if the local queue is exactly what we last applied from a
      // snapshot, this is just the apply's echo — don't re-broadcast it. A
      // genuine local change (add/remove/reorder/advance) differs, so it is
      // still sent even right after an apply.
      final applied = _lastAppliedSnapshot;
      if (applied != null) {
        final localIds =
            playerState.tracks.map((track) => track.id).toList(growable: false);
        if (_stringListEquality.equals(localIds, _queueIds(applied.queue))) {
          return;
        }
      }
      // Include ALL track types in the queue snapshot (Bug B2). Local
      // tracks are sent with metadata so members can see what's playing.
      final tracks = playerState.tracks.toList();

      // Window the sent queue around the active track so the worker's
      // 100-track cap always retains the active track. Otherwise, on a
      // >100-track playlist the active track falls outside the room queue
      // and members map it to index 0 → song restarts at 00:00.
      final activeId = playerState.activeTrack?.id;
      var windowStart = 0;
      if (activeId != null) {
        final activeIndex = tracks.indexWhere((t) => t.id == activeId);
        if (activeIndex > 10) windowStart = activeIndex - 10;
      }
      final windowEnd = (windowStart + 2000) < tracks.length
          ? windowStart + 2000
          : tracks.length;
      final maxTracks = tracks.sublist(windowStart, windowEnd);

      // Capture position synchronously before async calls for echo detection
      final positionMs = audioPlayer.position.inMilliseconds;
      _lastSentPositionMs = positionMs;
      _lastSentPositionAt = DateTime.now();

      // Capture active track synchronously to avoid race with source payload
      final activeTrack = playerState.activeTrack;

      _send("queue", {
        "queue": maxTracks.map((track) => track.toJson()).toList(),
        "activeTrackId": activeTrack?.id,
        "activeSource": await _activeSourcePayload(),
        "positionMs": positionMs,
        "loopMode": audioPlayer.loopMode.name,
        "shuffle": audioPlayer.isShuffled,
        "changeAt": DateTime.now().millisecondsSinceEpoch,
      });
    }());
  }

  void sendPlayback({bool passive = false, bool bypassSuppress = false}) async {
    // Genuine local play/pause must always reach the relay (bypassSuppress),
    // otherwise the completed-advance recovery's resume gets dropped and the
    // room is left stuck paused. Position-only syncs stay suppressed right
    // after an apply to avoid echoing back the snapshot we just applied.
    if (!bypassSuppress && _shouldSuppressOutboundSync) return;
    if (!_canSendRoomState) return;
    final positionMs = audioPlayer.position.inMilliseconds;
    _lastSentPositionMs = positionMs;
    _lastSentPositionAt = DateTime.now();

    // Capture active track synchronously before async calls to avoid race
    final activeTrack = ref.read(audioPlayerProvider).activeTrack;
    _send("playback", {
      "playing": audioPlayer.isPlaying,
      "positionMs": positionMs,
      // Passive ticks omit the active track/source so they never revert a
      // newer track change at the relay.
      if (!passive) "activeTrackId": activeTrack?.id,
      if (!passive) "activeSource": await _activeSourcePayload(),
      "loopMode": audioPlayer.loopMode.name,
      "shuffle": audioPlayer.isShuffled,
      "changeAt": DateTime.now().millisecondsSinceEpoch,
      if (passive) "passive": true,
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
    _send("roomSettings", {"communityQueueEnabled": enabled});
  }

  void setAutoAcceptSuggestedTracksEnabled(bool enabled) {
    if (!_guardPermission(
      MultiSessionPermission.editQueue,
      "edit the queue",
    )) {
      return;
    }
    _pushNotice(
      "Auto accept suggested tracks ${enabled ? "enabled" : "disabled"} by $_actorName",
    );
    _send("roomSettings", {"autoAcceptSuggestedTracks": enabled});
  }

  void setDiscordJoinEnabled(bool enabled) {
    if (!_guardPermission(
      MultiSessionPermission.editQueue,
      "edit room settings",
    )) {
      return;
    }
    _pushNotice(
      "Discord room joining ${enabled ? "enabled" : "disabled"} by $_actorName",
    );
    _send("roomSettings", {"discordJoinEnabled": enabled});
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
