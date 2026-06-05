import 'dart:async';
import 'dart:convert';

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

  @override
  MultiSessionState build() {
    ref.listen(audioPlayerProvider, (previous, next) {
      if (_applyingRemote || !state.connected) return;
      if (!state.can(MultiSessionPermission.editQueue)) return;

      final previousIds = previous?.tracks.map((track) => track.id).join(",");
      final nextIds = next.tracks.map((track) => track.id).join(",");
      if (previousIds != nextIds || previous?.currentIndex != next.currentIndex) {
        sendQueue();
      }
    });

    _positionTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_applyingRemote || !state.connected) return;
      if (!state.can(MultiSessionPermission.controlPlayback)) return;
      sendPlayback();
    });

    ref.onDispose(() {
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
    final relayUrl = ref.read(userPreferencesProvider).multiSessionRelayUrl.trim();
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
    final relayConfigurationError = _relayConfigurationError();
    if (relayConfigurationError != null) {
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
      await _connect();
      sendQueue();
      sendPlayback();
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      state = state.copyWith(
        connecting: false,
        error: _friendlyError(e),
      );
    }
  }

  Future<void> joinRoom(String code) async {
    final relayConfigurationError = _relayConfigurationError();
    if (relayConfigurationError != null) {
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
      await _connect();
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      state = state.copyWith(
        connecting: false,
        error: _friendlyError(e),
      );
    }
  }

  Future<void> _connect() async {
    final relayConfigurationError = _relayConfigurationError();
    if (relayConfigurationError != null) {
      state = state.copyWith(connected: false, error: relayConfigurationError);
      return;
    }

    _reconnectTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close(status.goingAway);

    final roomCode = state.code;
    final token = state.token;
    if (roomCode == null || token == null) return;

    final relayScheme =
        Uri.parse(ref.read(userPreferencesProvider).multiSessionRelayUrl).scheme;
    final uri = _relayUri("/rooms/$roomCode/ws").replace(
      scheme: relayScheme == "https" ? "wss" : "ws",
      queryParameters: {"token": token},
    );

    _channel = WebSocketChannel.connect(uri);
    await _channel!.ready;
    _subscription = _channel!.stream.listen(
      _handleMessage,
      onError: (error, stack) {
        AppLogger.reportError(error, stack);
        state = state.copyWith(
          connected: false,
          error: _friendlyError(error),
        );
        _scheduleReconnect();
      },
      onDone: () {
        state = state.copyWith(connected: false);
        _scheduleReconnect();
      },
    );
    state = state.copyWith(connected: true);
  }

  void _scheduleReconnect() {
    if (state.code == null || state.token == null) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      _connect();
    });
  }

  Future<void> _handleMessage(dynamic message) async {
    final event = jsonDecode(message as String) as Map<String, dynamic>;
    if (event["type"] == "ended") {
      await leaveRoom();
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
    if (state.isHost) return;
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
    if (!state.connected) return;
    _channel?.sink.add(encodeRoomEvent(type, data));
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
        for (final MapEntry(:key, :value) in permissions.entries) key.name: value,
      },
    });
  }

  Future<void> leaveRoom() async {
    _reconnectTimer?.cancel();
    _send("leave", null);
    await _subscription?.cancel();
    await _channel?.sink.close(status.goingAway);
    state = state.copyWith(clearRoom: true);
  }

  Future<void> endRoom() async {
    if (!state.isHost) {
      await leaveRoom();
      return;
    }

    _send("end", null);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await leaveRoom();
  }
}

final multiSessionProvider =
    NotifierProvider<MultiSessionNotifier, MultiSessionState>(
  () => MultiSessionNotifier(),
);
