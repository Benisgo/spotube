import 'dart:math';
import 'dart:async';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:spotube/extensions/list.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/state.dart';
import 'package:spotube/provider/blacklist_provider.dart';
import 'package:spotube/provider/database/database.dart';
import 'package:spotube/provider/discord_provider.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/provider/server/server.dart';
import 'package:spotube/provider/server/sourced_track_provider.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/logger/playback_start_trace.dart';
import 'package:spotube/services/youtube_engine/yt_dlp_worker.dart';
import 'package:spotube/utils/platform.dart';

final pendingPlaybackTrackIdProvider = StateProvider<String?>((ref) => null);

class AudioPlayerNotifier extends Notifier<AudioPlayerState> {
  BlackListNotifier get _blacklist => ref.read(blacklistProvider.notifier);
  String? _lastPersistedPlaylistSignature;

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

    final centerIndex = state.currentIndex < 0 ? 0 : state.currentIndex;
    final indexes = <int>{
      centerIndex - 1,
      centerIndex,
      centerIndex + 1,
    }.where((index) => index >= 0 && index < state.tracks.length);

    for (final index in indexes) {
      final track = state.tracks[index];
      if (track is SpotubeFullTrackObject) {
        unawaited(
          YtDlpExecutionContext.runBackground(() async {
            try {
              final isImmediateNext = index == centerIndex || index == centerIndex + 1;
              if (!isImmediateNext && !await _hasCachedSourceMatch(track)) {
                return;
              }
              final sourcedTrack =
                  await ref.read(sourcedTrackProvider(track).future);
              if (isImmediateNext &&
                  !sourcedTrack.hasFreshValidatedStream) {
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

  void setPendingPlaybackTrackId(String? trackId) {
    ref.read(pendingPlaybackTrackIdProvider.notifier).state = trackId;
  }

  void clearPendingPlaybackTrackId([String? trackId]) {
    final notifier = ref.read(pendingPlaybackTrackIdProvider.notifier);
    if (trackId == null || notifier.state == trackId) {
      notifier.state = null;
    }
  }

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
          data: {'hasFreshValidatedStream': sourcedTrack.hasFreshValidatedStream},
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
    if (kDebugMode && kIsWindows) {
      return;
    }

    final database = ref.read(databaseProvider);
    final preferences = await (database.select(database.preferencesTable)
          ..where((tbl) => tbl.id.equals(0)))
        .getSingleOrNull();
    final shouldResumeOnLaunch = preferences?.resumePlaybackOnLaunch ?? false;

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
        tracks.asMediaList(),
        initialIndex: safeCurrentIndex,
        autoPlay: false,
      );
      if (positionMs > 0) {
        await audioPlayer.seek(Duration(milliseconds: positionMs));
      }
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

  @override
  build() {
    var lastSavedPositionMs = -1;

    final subscriptions = [
      audioPlayer.playingStream.listen((playing) async {
        try {
          state = state.copyWith(playing: playing);
          final activeTrackId = state.activeTrack?.id;
          if (activeTrackId != null) {
            PlaybackStartTrace.markTrack(
              activeTrackId,
              playing ? 'player.playing_true' : 'player.playing_false',
            );
          }

          await _updatePlayerState(
            AudioPlayerStateTableCompanion(
              playing: Value(playing),
            ),
          );
        } catch (e, stack) {
          AppLogger.reportError(e, stack);
        }
      }),
      audioPlayer.loopModeStream.listen((loopMode) async {
        try {
          state = state.copyWith(loopMode: loopMode);

          await _updatePlayerState(
            AudioPlayerStateTableCompanion(
              loopMode: Value(loopMode),
            ),
          );
        } catch (e, stack) {
          AppLogger.reportError(e, stack);
        }
      }),
      audioPlayer.shuffledStream.listen((shuffled) async {
        try {
          state = state.copyWith(shuffled: shuffled);

          await _updatePlayerState(
            AudioPlayerStateTableCompanion(
              shuffled: Value(shuffled),
            ),
          );
        } catch (e, stack) {
          AppLogger.reportError(e, stack);
        }
      }),
      audioPlayer.playlistStream.listen((playlist) async {
        try {
          final signature =
              '${playlist.medias.length}:${playlist.index}:${playlist.medias.map((m) => m.uri).join("|")}';
          if (_lastPersistedPlaylistSignature == signature) return;
          _lastPersistedPlaylistSignature = signature;

          final tracks =
              playlist.medias.map((e) => SpotubeMedia.media(e).track).toList();

          state = state.copyWith(
            tracks: tracks,
            currentIndex: playlist.index,
          );
          if (state.activeTrack != null) {
            PlaybackStartTrace.markTrack(
              state.activeTrack!.id,
              'playlist_stream.updated',
              data: {
                'playlistLength': tracks.length,
                'currentIndex': playlist.index,
              },
            );
          }
          final pendingTrackId = ref.read(pendingPlaybackTrackIdProvider);
          if (pendingTrackId != null && state.activeTrack?.id == pendingTrackId) {
            clearPendingPlaybackTrackId(pendingTrackId);
          }
          _prefetchAdjacentSources();

          await _updatePlayerState(
            AudioPlayerStateTableCompanion(
              currentIndex: Value(state.currentIndex),
              tracks: Value(state.tracks),
            ),
          );
        } catch (e, stack) {
          AppLogger.reportError(e, stack);
        }
      }),
      audioPlayer.positionStream.listen((position) async {
        try {
          final activeTrackId = state.activeTrack?.id;
          if (activeTrackId != null && position > Duration.zero) {
            PlaybackStartTrace.completeTrack(
              activeTrackId,
              'player.first_position',
              data: {'positionMs': position.inMilliseconds},
            );
          }
          if (!audioPlayer.isPlaying) return;
          final positionMs = max(position.inMilliseconds, 0);
          if ((positionMs - lastSavedPositionMs).abs() < 5000) return;

          lastSavedPositionMs = positionMs;

          await _updatePlayerState(
            AudioPlayerStateTableCompanion(
              positionMs: Value(positionMs),
            ),
          );
        } catch (e, stack) {
          AppLogger.reportError(e, stack);
        }
      }),
    ];

    _syncSavedState();

    ref.onDispose(() {
      for (final subscription in subscriptions) {
        subscription.cancel();
      }
    });

    return AudioPlayerState(
      loopMode: audioPlayer.loopMode,
      playing: audioPlayer.isPlaying,
      shuffled: audioPlayer.isShuffled,
      tracks: [],
      collections: [],
    );
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

    state = state.copyWith(
      tracks: [...addableTracks, ...state.tracks],
    );

    for (int i = 0; i < addableTracks.length; i++) {
      final track = addableTracks.elementAt(i);

      await audioPlayer.addTrackAt(
        SpotubeMedia(track),
        max(state.currentIndex, 0) + i + 1,
      );
    }

    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        tracks: Value(state.tracks),
        currentIndex: Value(max(state.currentIndex, 0)),
        positionMs: const Value(0),
      ),
    );
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

    for (final track in tracks) {
      await audioPlayer.addTrack(SpotubeMedia(track));
    }

    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        tracks: Value(state.tracks),
        currentIndex: Value(max(state.currentIndex, 0)),
        positionMs: const Value(0),
      ),
    );
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
    _assertAllowedTracks(tracks);
    final targetTrack =
        tracks.isEmpty ? null : tracks[initialIndex.clamp(0, tracks.length - 1)];
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

    // Resolve the first track's CDN URL directly so MPV can play it without
    // going through the local proxy (which has issues on some Android devices)
    String? firstTrackDirectUrl;
    if (targetTrack != null && targetTrack is SpotubeFullTrackObject && !kIsDesktop) {
      try {
        final notifier = ref.read(sourcedTrackProvider(targetTrack).notifier);
        final sourced = await ref.read(sourcedTrackProvider(targetTrack).future);
        if (sourced?.url != null) {
          await notifier.refreshStreamingUrl();
          firstTrackDirectUrl = notifier.state.value?.url;
        }
      } catch (_) {}
    }

    final medias = _blacklist
        .filter(tracks)
        .toList()
        .asMediaList(firstTrackDirectUrl: firstTrackDirectUrl, targetTrack: targetTrack)
        .unique((a, b) => a.uri == b.uri);

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
    PlaybackStartTrace.markTrack(selectedTrack.id, 'audio_player.open_playlist.done');

    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        tracks: Value(state.tracks),
        currentIndex: Value(max(state.currentIndex, 0)),
        positionMs: const Value(0),
      ),
    );
    PlaybackStartTrace.markTrack(selectedTrack.id, 'audio_player_notifier.load.done');
  }

  Future<void> swapActiveSource() async {
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

final audioPlayerProvider =
    NotifierProvider<AudioPlayerNotifier, AudioPlayerState>(
  () => AudioPlayerNotifier(),
);
