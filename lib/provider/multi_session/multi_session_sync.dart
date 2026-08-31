part of 'multi_session.dart';

/// Snapshot reconciliation + shared sync state for [MultiSessionNotifier].
///
/// Owns ALL of the notifier's mutable state (WebSocket channel, timers,
/// snapshot bookkeeping, observed position) plus the pure reconciliation
/// helpers: snapshot dedup/skip heuristics, the snapshot apply pipeline, and
/// the permission/outbound-sync guards. Kept in a separate `part` file so the
/// notifier core stays focused on wiring streams in [build].
mixin MultiSessionSync on Notifier<MultiSessionState> {
  /// Resolves the shared audio engine through Riverpod.
  SpotubeAudioPlayer get audioPlayer => ref.read(audioPlayerServiceProvider);
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
}
