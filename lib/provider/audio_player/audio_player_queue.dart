part of 'audio_player.dart';

/// Queue & collection mutation operations for [AudioPlayerNotifier].
///
/// Owns adding/removing tracks and collections, queue reconciliation against
/// the player's actual playlist, loading a new queue, transport commands
/// (jump / move / stop / source swap), and the adjacent-track prefetching.
/// Kept in a separate `part` file so the notifier core stays focused on
/// playback orchestration and stream wiring.
mixin AudioPlayerQueueOps on AudioPlayerPersistence {
  BlackListNotifier get _blacklist => ref.read(blacklistProvider.notifier);
  int? _lastPersistedPlaylistLength;
  int? _lastPersistedIndex;
  int _playlistOperationId = 0;
  bool _isBatchAdding = false;

  /// How many tracks are added per native call before yielding to the event
  /// loop. Keeps large queue operations (e.g. queueing a 3300-track playlist)
  /// cooperative on the UI isolate.
  static const int _addBatchYieldInterval = 100;

  bool _isExpectedBackgroundPrefetchSkip(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('yt-dlp worker unavailable') ||
        message.contains('background worker deferred') ||
        message.contains('worker cancelled') ||
        message.contains('yt-dlp fallback requested');
  }

  Future<bool> _hasCachedSourceMatch(SpotubeFullTrackObject track) async {
    final audioSource = await ref.read(audioSourcePluginProvider.future);
    final database = ref.read(databaseProvider);
    if (audioSource == null) return false;

    final cached = await (database.select(database.sourceMatchTable)
          ..where((tbl) =>
              tbl.trackId.equals(track.id) &
              tbl.sourceType.equals(audioSource.slug))
          ..limit(1))
        .getSingleOrNull();
    return cached != null;
  }

  void _prefetchAdjacentSources() {
    if (state.tracks.isEmpty || YtDlpWorkerClient.shouldDeferBackgroundWork) {
      return;
    }
    // Skip prefetching when tracks are cascading through expired URLs.
    // This prevents flooding the yt-dlp worker with unnecessary fetches
    // while MPV burns through the playlist on failed streams.
    if (audioPlayer.isTrackCascadeActive) return;
    // Also skip prefetching when the player is not actively playing
    if (!audioPlayer.isPlaying) return;

    final centerIndex = state.currentIndex < 0 ? 0 : state.currentIndex;
    // On mobile (slow CPU, debug builds) prefetching 3 tracks at once
    // saturates the device with concurrent stream resolutions, stalling the
    // actively-playing track. Only prefetch the immediate next track so the
    // current + previous don't fight the player for CPU and network.
    final indexes = <int>{
      if (kIsMobile)
        centerIndex + 1
      else ...[centerIndex - 1, centerIndex, centerIndex + 1],
    }.where((index) => index >= 0 && index < state.tracks.length);

    for (final index in indexes) {
      final track = state.tracks[index];
      if (track is SpotubeFullTrackObject) {
        unawaited(
          YtDlpExecutionContext.runBackground(() async {
            try {
              final isImmediateNext =
                  index == centerIndex || index == centerIndex + 1;
              if (!isImmediateNext && !await _hasCachedSourceMatch(track)) {
                return;
              }
              final sourcedTrack =
                  await ref.read(sourcedTrackProvider(track).future);
              if (isImmediateNext && !sourcedTrack.hasFreshValidatedStream) {
                await ref
                    .read(sourcedTrackProvider(track).notifier)
                    .refreshStreamingUrl()
                    .catchError((_) => sourcedTrack);
              }
            } catch (error, stack) {
              if (_isExpectedBackgroundPrefetchSkip(error)) {
                return;
              }
              await AppLogger.reportError(
                error,
                stack,
                "Failed to prefetch sourced track ${track.id}",
              );
            }
          }, cancelGroup: 'adjacent-prefetch:${track.id}'),
        );
      }
    }
  }

  void _assertAllowedTracks(Iterable<SpotubeTrackObject> tracks) {
    assert(
      tracks.every(
        (track) =>
            track is SpotubeFullTrackObject || track is SpotubeLocalTrackObject,
      ),
      'All tracks must be either SpotubeFullTrackObject or SpotubeLocalTrackObject',
    );
  }

  void _assertAllowedTrack(SpotubeTrackObject tracks) {
    assert(
      tracks is SpotubeFullTrackObject || tracks is SpotubeLocalTrackObject,
      'Track must be either SpotubeFullTrackObject or SpotubeLocalTrackObject',
    );
  }

  /// Reconciles the queue state against the player's ACTUAL playlist content.
  /// `state.tracks` is set optimistically up-front before the batch adds, so if
  /// a batch was partially applied (a track failed to add, or a concurrent
  /// batch op was superseded mid-flight), the player is the source of truth.
  /// Without this, the queue UI and DB would show tracks that were never added
  /// (the pre-batch per-add snapshots that used to self-heal are suppressed).
  void _reconcileQueueWithPlayer() {
    final actual = audioPlayer.playlist.medias
        .map((media) => SpotubeMedia.media(media).track)
        .toList();
    if (actual.length == state.tracks.length) return;
    final safeIndex = actual.isEmpty
        ? -1
        : state.currentIndex.clamp(0, actual.length - 1).toInt();
    state = state.copyWith(tracks: actual, currentIndex: safeIndex);
  }

  // Collection related methods
  Future<void> addCollections(List<String> collectionIds) async {
    state = state.copyWith(collections: [
      ...state.collections,
      ...collectionIds,
    ]);

    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        collections: Value(state.collections),
      ),
    );
  }

  Future<void> addCollection(String collectionId) async {
    await addCollections([collectionId]);
  }

  Future<void> removeCollections(List<String> collectionIds) async {
    state = state.copyWith(
      collections: state.collections
          .where((element) => !collectionIds.contains(element))
          .toList(),
    );

    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        collections: Value(state.collections),
      ),
    );
  }

  Future<void> removeCollection(String collectionId) async {
    await removeCollections([collectionId]);
  }

  Future<void> addTracksAtFirst(
    Iterable<SpotubeTrackObject> tracks, {
    bool allowDuplicates = false,
  }) async {
    _assertAllowedTracks(tracks);
    final addableTracks = _blacklist
        .filter(tracks)
        .where(
          (track) =>
              allowDuplicates ||
              !state.tracks.any((element) => _compareTracks(element, track)),
        )
        .toList();
    if (addableTracks.isEmpty) return;

    if (state.tracks.isEmpty ||
        state.currentIndex < 0 ||
        !audioPlayer.hasSource) {
      state = state.copyWith(
        tracks: [...addableTracks, ...state.tracks],
        currentIndex: -1,
      );

      await _updatePlayerState(
        AudioPlayerStateTableCompanion(
          tracks: Value(state.tracks),
          currentIndex: const Value(-1),
          positionMs: const Value(0),
        ),
      );
      return;
    }

    if (state.tracks.length == 1) {
      return addTracks(addableTracks, allowDuplicates: true);
    }

    // Build the local queue in the SAME order the media_kit playlist will
    // actually have after the insertions below (insert after the current
    // track). Previously this PREPENDED the new tracks to state.tracks while
    // addTrackAt inserted them after currentIndex; the mismatch was never
    // reconciled (the _isBatchAdding flag suppresses the playlistStream
    // listener during the batch), so the queue UI and the room broadcast
    // showed "Play Next" tracks at the FRONT instead of right after the
    // current track.
    final insertIndex = max(state.currentIndex, 0) + 1;
    state = state.copyWith(
      tracks: [
        ...state.tracks.sublist(0, insertIndex),
        ...addableTracks,
        ...state.tracks.sublist(insertIndex),
      ],
    );

    _playlistOperationId++;
    final currentOperationId = _playlistOperationId;
    _isBatchAdding = true;
    audioPlayer.beginBatchAdd();

    try {
      var added = 0;
      for (int i = 0; i < addableTracks.length; i++) {
        if (_playlistOperationId != currentOperationId) break;
        final track = addableTracks.elementAt(i);

        await audioPlayer.addTrackAt(
          SpotubeMedia(track),
          max(state.currentIndex, 0) + i + 1,
        );
        if (++added % _addBatchYieldInterval == 0) {
          // Yield to the frame scheduler so long batches stay cooperative.
          await Future<void>.delayed(Duration.zero);
        }
      }
    } finally {
      // Always end the service batch (ref-counted, idempotent); it never emits
      // a snapshot, so a superseded batch can't clobber a newer op's state.
      await audioPlayer.endBatchAdd();
      if (_playlistOperationId == currentOperationId) {
        _isBatchAdding = false;
        // Reconcile against the player's ACTUAL content (partial-add failure or
        // a superseded concurrent op) before persisting.
        _reconcileQueueWithPlayer();
        await _updatePlayerState(
          AudioPlayerStateTableCompanion(
            tracks: Value(state.tracks),
            currentIndex: Value(max(state.currentIndex, 0)),
            positionMs: const Value(0),
          ),
        );
        // Refresh the persisted bookkeeping: the playlistStream listener never
        // fired during the batch, so without this the first post-batch index
        // change would be misclassified as a structural change (one full O(n)
        // remap + redundant 3000-track DB write on the next skip).
        _lastPersistedPlaylistLength = state.tracks.length;
        _lastPersistedIndex = state.currentIndex;
      }
    }
  }

  Future<void> addTrack(SpotubeTrackObject track) async {
    _assertAllowedTrack(track);

    if (_blacklist.contains(track)) return;
    if (state.tracks.any((element) => _compareTracks(element, track))) return;

    if (!audioPlayer.hasSource || state.currentIndex < 0) {
      state = state.copyWith(
        tracks: [...state.tracks, track],
        currentIndex: -1,
      );

      await _updatePlayerState(
        AudioPlayerStateTableCompanion(
          tracks: Value(state.tracks),
          currentIndex: const Value(-1),
          positionMs: const Value(0),
        ),
      );
      return;
    }

    state = state.copyWith(
      tracks: [...state.tracks, track],
    );

    await audioPlayer.addTrack(SpotubeMedia(track));

    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        tracks: Value(state.tracks),
        currentIndex: Value(max(state.currentIndex, 0)),
        positionMs: const Value(0),
      ),
    );
  }

  Future<void> addTracks(
    Iterable<SpotubeTrackObject> tracks, {
    bool allowDuplicates = false,
  }) async {
    _assertAllowedTracks(tracks);

    tracks = _blacklist.filter(tracks).where((track) {
      return allowDuplicates ||
          !state.tracks.any((element) => _compareTracks(element, track));
    }).toList();
    if (tracks.isEmpty) return;

    if (!audioPlayer.hasSource || state.currentIndex < 0) {
      state = state.copyWith(
        tracks: [...state.tracks, ...tracks],
        currentIndex: -1,
      );

      await _updatePlayerState(
        AudioPlayerStateTableCompanion(
          tracks: Value(state.tracks),
          currentIndex: const Value(-1),
          positionMs: const Value(0),
        ),
      );
      return;
    }

    state = state.copyWith(
      tracks: [...state.tracks, ...tracks],
    );

    _playlistOperationId++;
    final currentOperationId = _playlistOperationId;
    _isBatchAdding = true;
    audioPlayer.beginBatchAdd();

    try {
      var added = 0;
      for (final track in tracks) {
        if (_playlistOperationId != currentOperationId) break;
        await audioPlayer.addTrack(SpotubeMedia(track));
        if (++added % _addBatchYieldInterval == 0) {
          // Yield to the frame scheduler so long batches stay cooperative.
          await Future<void>.delayed(Duration.zero);
        }
      }
    } finally {
      // Always end the service batch (ref-counted, idempotent); it never emits
      // a snapshot, so a superseded batch can't clobber a newer op's state.
      await audioPlayer.endBatchAdd();
      if (_playlistOperationId == currentOperationId) {
        _isBatchAdding = false;
        // Reconcile against the player's ACTUAL content (partial-add failure or
        // a superseded concurrent op) before persisting.
        _reconcileQueueWithPlayer();
        await _updatePlayerState(
          AudioPlayerStateTableCompanion(
            tracks: Value(state.tracks),
            currentIndex: Value(max(state.currentIndex, 0)),
            positionMs: const Value(0),
          ),
        );
        // Refresh the persisted bookkeeping: the playlistStream listener never
        // fired during the batch, so without this the first post-batch index
        // change would be misclassified as a structural change (one full O(n)
        // remap + redundant 3000-track DB write on the next skip).
        _lastPersistedPlaylistLength = state.tracks.length;
        _lastPersistedIndex = state.currentIndex;
        // Prefetch the active track's sources once now that the batch
        // is done (it was skipped during the batch to avoid the 429 storm).
        _prefetchAdjacentSources();
      }
    }
  }

  Future<void> removeTrack(String trackId) async {
    final index = state.tracks.indexWhere((element) => element.id == trackId);

    if (index == -1) return;

    state = state.copyWith(
      tracks: List.of(state.tracks)..removeAt(index),
    );

    await audioPlayer.removeTrack(index);

    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        tracks: Value(state.tracks),
        currentIndex: Value(max(state.currentIndex, 0)),
        positionMs: const Value(0),
      ),
    );
  }

  Future<void> removeTracks(Iterable<String> trackIds) async {
    final trackIndexes = state.tracks
        .where((element) => trackIds.any((trackId) => trackId == element.id))
        .mapIndexed((index, element) => index);

    final tracks = state.tracks.where(
      (element) => !trackIds.contains(element.id),
    );

    state = state.copyWith(
      tracks: tracks.toList(),
    );

    for (final index in trackIndexes) {
      await audioPlayer.removeTrack(index);
    }

    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        tracks: Value(state.tracks),
        currentIndex: Value(max(state.currentIndex, 0)),
        positionMs: const Value(0),
      ),
    );
  }

  bool _compareTracks(SpotubeTrackObject a, SpotubeTrackObject b) {
    if (a.runtimeType != b.runtimeType) {
      return false;
    }

    return a is SpotubeLocalTrackObject && b is SpotubeLocalTrackObject
        ? a.path == b.path
        : a.id == b.id;
  }

  Future<void> load(
    List<SpotubeTrackObject> tracks, {
    int initialIndex = 0,
    bool autoPlay = false,
  }) async {
    _playlistOperationId++;
    _isBatchAdding = false;
    _assertAllowedTracks(tracks);
    final targetTrack = tracks.isEmpty
        ? null
        : tracks[initialIndex.clamp(0, tracks.length - 1)];
    if (targetTrack != null) {
      PlaybackStartTrace.markTrack(
        targetTrack.id,
        'audio_player_notifier.load.start',
        data: {'trackCount': tracks.length, 'initialIndex': initialIndex},
      );
    }
    await ref.read(serverProvider.future);
    if (targetTrack != null) {
      PlaybackStartTrace.markTrack(targetTrack.id, 'server.ready');
    }

    final database = ref.read(databaseProvider);
    final preferences = await (database.select(database.preferencesTable)
          ..where((tbl) => tbl.id.equals(0)))
        .getSingleOrNull();
    final downloadLocation = preferences?.downloadLocation ?? "";

    final filteredTracks = _blacklist.filter(tracks).toList();
    // Build media list — skip findDownloadedFile for non-target tracks
    // to avoid N filesystem checks for large playlists on Android.
    final seenUris = <String>{};
    final medias = filteredTracks
        .asMediaList(
          targetTrack: targetTrack,
          downloadLocation: downloadLocation,
        )
        // O(N) dedup via Set instead of O(N²) .unique()
        .where((m) => seenUris.add(m.uri))
        .toList();

    if (medias.isEmpty) {
      if (targetTrack != null) {
        PlaybackStartTrace.failTrack(targetTrack.id, 'load.no_playable_media');
      }
      return;
    }

    final safeInitialIndex = initialIndex.clamp(0, medias.length - 1).toInt();
    final selectedTrack = medias[safeInitialIndex].track;

    state = state.copyWith(
      // These are filtered tracks as well
      tracks: medias.map((media) => media.track).toList(),
      currentIndex: safeInitialIndex,
      collections: [],
    );
    _prefetchAdjacentSources();
    PlaybackStartTrace.markTrack(
      selectedTrack.id,
      'audio_player.open_playlist.start',
      data: {'mediaCount': medias.length, 'autoPlay': autoPlay},
    );
    await audioPlayer.openPlaylist(
      medias,
      initialIndex: safeInitialIndex,
      autoPlay: autoPlay,
    );
    PlaybackStartTrace.markTrack(
        selectedTrack.id, 'audio_player.open_playlist.done');

    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        tracks: Value(state.tracks),
        currentIndex: Value(max(state.currentIndex, 0)),
        positionMs: const Value(0),
      ),
    );
    PlaybackStartTrace.markTrack(
        selectedTrack.id, 'audio_player_notifier.load.done');
  }

  Future<void> swapActiveSource() async {
    _playlistOperationId++;
    _isBatchAdding = false;
    if (state.tracks.isEmpty || state.activeTrack is! SpotubeFullTrackObject) {
      return;
    }

    final oldState = state;
    await audioPlayer.stop();

    await load(
      oldState.tracks,
      initialIndex: oldState.currentIndex,
      autoPlay: true,
    );
    state = state.copyWith(
      collections: oldState.collections,
      loopMode: oldState.loopMode,
      playing: oldState.playing,
      shuffled: false,
    );
    await audioPlayer.setLoopMode(oldState.loopMode);
    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        tracks: Value(state.tracks),
        currentIndex: Value(state.currentIndex),
        collections: Value(state.collections),
        loopMode: Value(state.loopMode),
        playing: Value(state.playing),
        shuffled: Value(state.shuffled),
        positionMs: Value(max(audioPlayer.position.inMilliseconds, 0)),
      ),
    );
  }

  Future<void> jumpToTrack(SpotubeTrackObject track) async {
    final pendingId = ref.read(pendingPlaybackTrackIdProvider);
    if (pendingId != null && pendingId != track.id) return;
    final index =
        state.tracks.toList().indexWhere((element) => element.id == track.id);
    if (index == -1) return;
    PlaybackStartTrace.markTrack(
      track.id,
      'audio_player_notifier.jump.start',
      data: {'index': index},
    );
    await audioPlayer.jumpTo(index);
    PlaybackStartTrace.markTrack(track.id, 'audio_player_notifier.jump.done');
  }

  Future<void> moveTrack(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex ||
        newIndex < 0 ||
        oldIndex < 0 ||
        newIndex > state.tracks.length - 1 ||
        oldIndex > state.tracks.length - 1) {
      return;
    }

    await audioPlayer.moveTrack(oldIndex, newIndex);
  }

  Future<void> stop() async {
    _playlistOperationId++;
    _isBatchAdding = false;
    state = state.copyWith(
      tracks: [],
      currentIndex: -1,
      collections: [],
      loopMode: PlaylistMode.none,
      playing: false,
      shuffled: false,
    );
    await audioPlayer.stop();
    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        tracks: Value(state.tracks),
        currentIndex: const Value(-1),
        collections: const Value(<String>[]),
        loopMode: const Value(PlaylistMode.none),
        playing: const Value(false),
        shuffled: const Value(false),
        positionMs: const Value(0),
      ),
    );
    ref.read(discordProvider.notifier).clear();
  }
}
