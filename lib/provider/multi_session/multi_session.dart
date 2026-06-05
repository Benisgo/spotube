import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/models/multi_session/multi_session.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/metadata_plugin/core/user.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/device_info/device_info.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

class MultiSessionNotifier extends Notifier<MultiSessionState> {
  static const _legacyRelayUrl = "https://spotube-multi-session.workers.dev";

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

  void _debugTrace(String message) {
    if (!kDebugMode) return;
    // ignore: avoid_print
    print('[multi-session] $message');
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

  @override
  MultiSessionState build() {
    ref.listen(audioPlayerProvider, (previous, next) {
      if (!_canEditQueue) return;

      final previousIds = previous?.tracks.map((track) => track.id).join(",");
      final nextIds = next.tracks.map((track) => track.id).join(",");
      if (previousIds != nextIds ||
          previous?.currentIndex != next.currentIndex) {
        sendQueue();
      }
    });

    final playingSubscription = audioPlayer.playingStream.listen((_) {
      if (!_canControlPlayback) return;
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

      // Detect explicit seeks or jumps without broadcasting every tick.
      if ((position.inMilliseconds - expectedPositionMs).abs() > 1500) {
        sendPlayback();
      }
    });

    _positionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_canControlPlayback) return;
      _rememberObservedPosition(audioPlayer.position);
      sendPlayback();
    });

    ref.onDispose(() {
      playingSubscription.cancel();
      positionSubscription.cancel();
      _positionTimer?.cancel();
      _reconnectTimer?.cancel();
      _subscription?.cancel();
      _channel?.sink.close(status.goingAway);
    });

    return const MultiSessionState();
  }

  Uri _relayUri(String path) {
    final relayUrl = ref.read(userPreferencesProvider).multiSessionRelayUrl;
    final base = Uri.parse(relayUrl.endsWith("/")
        ? relayUrl.substring(0, relayUrl.length - 1)
        : relayUrl);
    final basePath = base.path.endsWith("/")
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(path: "$basePath$path");
  }

  String? _relayConfigurationError() {
    final relayUrl =
        ref.read(userPreferencesProvider).multiSessionRelayUrl.trim();
    if (relayUrl.isEmpty || relayUrl == _legacyRelayUrl) {
      return "Multi-Session relay is not configured. Open Settings > Playback > Multi-Session relay and enter a live relay URL.";
    }

    final uri = Uri.tryParse(relayUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
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

  Future<String> _participantName() async {
    final user = await ref.read(metadataPluginUserProvider.future);
    final userName = user?.name.trim();
    if (userName != null && userName.isNotEmpty) {
      return userName;
    }

    return DeviceInfoService.instance.computerName();
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
        body: jsonEncode({"name": await _participantName()}),
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

  Future<void> joinRoom(String code) async {
    _debugTrace('joinRoom:start:${code.trim().toUpperCase()}');
    final relayConfigurationError = _relayConfigurationError();
    if (relayConfigurationError != null) {
      _debugTrace('joinRoom:config-error');
      state = state.copyWith(connecting: false, error: relayConfigurationError);
      return;
    }

    state = state.copyWith(connecting: true, clearError: true);
    try {
      final normalizedCode = code.trim().toUpperCase();
      final res = await http.post(
        _relayUri("/rooms/$normalizedCode/join"),
        headers: {"content-type": "application/json"},
        body: jsonEncode({"name": await _participantName()}),
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

  Future<void> _connect() async {
    _debugTrace('connect:start code=${state.code} gen=${_connectionGeneration + 1}');
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

    final relayScheme =
        Uri.parse(ref.read(userPreferencesProvider).multiSessionRelayUrl)
            .scheme;
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
    _debugTrace('message:type=${event["type"]} gen=$generation code=${state.code}');
    if (event["type"] == "ended") {
      _beginRoomShutdown(notifyRelay: false, endedByHost: true);
      state = const MultiSessionState(error: "Room ended");
      return;
    }

    if (event["type"] != "snapshot") return;

    final snapshot = MultiSessionRoomSnapshot.fromJson(
      (event["data"] as Map).cast<String, dynamic>(),
    );
    if ((state.snapshot?.sequence ?? -1) > snapshot.sequence) return;

    state = state.copyWith(snapshot: snapshot, code: snapshot.code);
    await _applySnapshot(snapshot);
  }

  Future<void> _applySnapshot(MultiSessionRoomSnapshot snapshot) async {
    if (_closingRoom || _intentionalDisconnect) return;
    _debugTrace(
      'snapshot:apply seq=${snapshot.sequence} queue=${snapshot.queue.length} code=${snapshot.code}',
    );
    _applyingRemote = true;
    try {
      final tracks = snapshot.queue
          .map(SpotubeTrackObject.fromJson)
          .whereType<SpotubeFullTrackObject>()
          .toList();
      if (tracks.isEmpty) return;

      final activeIndex = snapshot.activeTrackId == null
          ? 0
          : tracks.indexWhere((track) => track.id == snapshot.activeTrackId);

      final localState = ref.read(audioPlayerProvider);
      final localIds = localState.tracks.map((track) => track.id).join(",");
      final remoteIds = tracks.map((track) => track.id).join(",");
      final index = activeIndex < 0 ? 0 : activeIndex;

      if (localIds != remoteIds || localState.currentIndex != index) {
        await ref.read(audioPlayerProvider.notifier).load(
              tracks,
              initialIndex: index,
              autoPlay: snapshot.playing,
            );
      }

      await audioPlayer.seek(Duration(milliseconds: snapshot.positionMs));
      _rememberObservedPosition(Duration(milliseconds: snapshot.positionMs));
      if (snapshot.playing && !audioPlayer.isPlaying) {
        await audioPlayer.resume();
      } else if (!snapshot.playing && audioPlayer.isPlaying) {
        await audioPlayer.pause();
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

    if (channel != null && !kDebugMode) {
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

  void _beginRoomShutdown({
    required bool notifyRelay,
    required bool endedByHost,
  }) {
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

    Timer.run(() {
      unawaited(() async {
        try {
          if (notifyRelay && previousState.connected && !kDebugMode) {
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
      }());
    });
  }

  void sendQueue() {
    final playerState = ref.read(audioPlayerProvider);
    _send("queue", {
      "queue": playerState.tracks
          .whereType<SpotubeFullTrackObject>()
          .map((track) => track.toJson())
          .toList(),
      "activeTrackId": playerState.activeTrack?.id,
    });
  }

  void sendPlayback() {
    _send("playback", {
      "playing": audioPlayer.isPlaying,
      "positionMs": audioPlayer.position.inMilliseconds,
      "activeTrackId": ref.read(audioPlayerProvider).activeTrack?.id,
    });
  }

  void setMemberPermissions(
    String memberId,
    Map<MultiSessionPermission, bool> permissions,
  ) {
    if (!state.can(MultiSessionPermission.manageMembers)) return;
    _send("permissions", {
      "memberId": memberId,
      "permissions": {
        for (final MapEntry(:key, :value) in permissions.entries)
          key.name: value,
      },
    });
  }

  Future<void> leaveRoom() async {
    _beginRoomShutdown(notifyRelay: true, endedByHost: false);
  }

  Future<void> endRoom() async {
    if (!state.isHost) {
      await leaveRoom();
      return;
    }
    _beginRoomShutdown(notifyRelay: true, endedByHost: false);
  }
}

final multiSessionProvider =
    NotifierProvider<MultiSessionNotifier, MultiSessionState>(
  () => MultiSessionNotifier(),
);
