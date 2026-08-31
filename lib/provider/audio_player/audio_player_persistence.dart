part of 'audio_player.dart';

/// Playback-state persistence + track priming for [AudioPlayerNotifier].
///
/// Owns loading the saved queue from the Drift database on startup
/// ([_syncSavedState]), writing incremental state snapshots back to it
/// ([_updatePlayerState]), and pre-resolving a track's streaming URL
/// ([primeTrackPlayback]). Kept in a separate `part` file so the notifier
/// core stays focused on playback orchestration and stream wiring.
mixin AudioPlayerPersistence on Notifier<AudioPlayerState> {
  /// Resolves the shared audio engine through Riverpod so it can be
  /// overridden in tests / with alternate backends.
  SpotubeAudioPlayer get audioPlayer => ref.read(audioPlayerServiceProvider);

  Future<void> primeTrackPlayback(
    SpotubeTrackObject track, {
    bool refreshStream = true,
  }) async {
    if (track is! SpotubeFullTrackObject) return;

    try {
      await YtDlpExecutionContext.runForeground(() async {
        PlaybackStartTrace.markTrack(track.id, 'prime_track.start');
        final sourcedTrack = await ref.read(sourcedTrackProvider(track).future);
        PlaybackStartTrace.markTrack(
          track.id,
          'prime_track.sourced_ready',
          data: {
            'hasFreshValidatedStream': sourcedTrack.hasFreshValidatedStream
          },
        );
        if (refreshStream && !sourcedTrack.hasFreshValidatedStream) {
          PlaybackStartTrace.markTrack(
            track.id,
            'prime_track.refresh_stream.start',
          );
          await ref
              .read(sourcedTrackProvider(track).notifier)
              .refreshStreamingUrl();
          PlaybackStartTrace.markTrack(
            track.id,
            'prime_track.refresh_stream.done',
          );
        }
        PlaybackStartTrace.markTrack(track.id, 'prime_track.done');
      }, cancelGroup: 'playback:${track.id}');
    } catch (error, stack) {
      PlaybackStartTrace.markTrack(
        track.id,
        'prime_track.failed',
        data: {'error': error.toString()},
      );
      await AppLogger.reportError(
        error,
        stack,
        "Failed to prime track playback ${track.id}",
      );
    }
  }

  Future<void> _syncSavedState() async {
    final database = ref.read(databaseProvider);
    final preferences = await (database.select(database.preferencesTable)
          ..where((tbl) => tbl.id.equals(0)))
        .getSingleOrNull();
    final shouldResumeOnLaunch = preferences?.resumePlaybackOnLaunch ?? false;
    final downloadLocation = preferences?.downloadLocation ?? "";

    var playerState =
        await database.select(database.audioPlayerStateTable).getSingleOrNull();

    if (playerState == null) {
      await database.into(database.audioPlayerStateTable).insert(
            AudioPlayerStateTableCompanion.insert(
              playing: audioPlayer.isPlaying,
              loopMode: audioPlayer.loopMode,
              shuffled: audioPlayer.isShuffled,
              collections: <String>[],
              tracks: const Value(<SpotubeTrackObject>[]),
              currentIndex: const Value(0),
              positionMs: const Value(0),
              id: const Value(0),
            ),
          );

      playerState =
          await database.select(database.audioPlayerStateTable).getSingle();
    } else {
      await audioPlayer.setLoopMode(playerState.loopMode);
      await audioPlayer.setShuffle(playerState.shuffled);
    }

    final tracks = playerState.tracks;
    final currentIndex = playerState.currentIndex;
    final positionMs = max(playerState.positionMs, 0);

    if (tracks.isEmpty && state.tracks.isNotEmpty) {
      await _updatePlayerState(
        AudioPlayerStateTableCompanion(
          tracks: Value(state.tracks),
          currentIndex: Value(currentIndex),
        ),
      );
    } else if (tracks.isNotEmpty && shouldResumeOnLaunch) {
      final safeCurrentIndex = currentIndex.clamp(0, tracks.length - 1).toInt();
      state = state.copyWith(
        tracks: tracks,
        currentIndex: safeCurrentIndex,
      );
      await audioPlayer.openPlaylist(
        tracks.asMediaList(downloadLocation: downloadLocation),
        initialIndex: safeCurrentIndex,
        autoPlay: false,
      );
      if (positionMs > 0) {
        await audioPlayer.seek(Duration(milliseconds: positionMs));
      }
      // Prime the resumed track so its stream is resolved immediately
      unawaited(primeTrackPlayback(tracks[safeCurrentIndex]));
    }

    if (playerState.collections.isNotEmpty) {
      state = state.copyWith(
        collections: playerState.collections,
      );
    }
  }

  Future<void> _updatePlayerState(
    AudioPlayerStateTableCompanion companion,
  ) async {
    final database = ref.read(databaseProvider);

    await (database.update(database.audioPlayerStateTable)
          ..where((tb) => tb.id.equals(0)))
        .write(companion);
  }
}
