part of 'multi_session.dart';

/// Relay transport + room lifecycle for [MultiSessionNotifier].
///
/// Owns relay URL normalization/validation, participant payload building,
/// room creation/joining, the WebSocket connection + reconnect, message
/// handling, outbound queue/playback sends, and room shutdown (leave/end).
/// Kept in a separate `part` file so the notifier core stays focused on
/// wiring streams in [build].
mixin MultiSessionRelay on MultiSessionSync {
  static const _legacyRelayUrl = "https://spotube-multi-session.workers.dev";

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
        if (MultiSessionSync._stringListEquality
            .equals(localIds, _queueIds(applied.queue))) {
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
