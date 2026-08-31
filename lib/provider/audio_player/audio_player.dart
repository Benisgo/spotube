import 'dart:math';
import 'dart:async';

import 'package:drift/drift.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/audio_player_service_provider.dart';
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

part 'audio_player_persistence.dart';
part 'audio_player_queue.dart';

final pendingPlaybackTrackIdProvider = StateProvider<String?>((ref) => null);

/// Monotonically increasing counter for track tap operations.
/// Captured at the start of a tap callback and checked before performing
/// the actual playback command. If the counter changed, another tap
/// happened in the meantime and this call is stale — abort.
int _trackTapGeneration = 0;

class AudioPlayerNotifier extends Notifier<AudioPlayerState>
    with AudioPlayerPersistence, AudioPlayerQueueOps {
  void setPendingPlaybackTrackId(String? trackId) {
    ref.read(pendingPlaybackTrackIdProvider.notifier).state = trackId;
  }

  void clearPendingPlaybackTrackId([String? trackId]) {
    final notifier = ref.read(pendingPlaybackTrackIdProvider.notifier);
    if (trackId == null || notifier.state == trackId) {
      notifier.state = null;
    }
  }

  /// Returns the current track-tap generation and advances the counter.
  /// Each tap on a track increments this. Callers should capture the
  /// returned value at the start of their async operation and compare
  /// against [trackTapGeneration] before performing the playback command.
  int generateTrackTap() => ++_trackTapGeneration;

  /// The current track-tap generation counter.
  int get trackTapGeneration => _trackTapGeneration;

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
        final streamSeq = _playlistOperationId;
        try {
          final playlistLength = playlist.medias.length;
          final onlyIndexChanged =
              _lastPersistedPlaylistLength == playlistLength &&
                  _lastPersistedIndex != playlist.index;

          // Skip if nothing changed at all.
          if (_lastPersistedIndex == playlist.index &&
              _lastPersistedPlaylistLength == playlistLength) {
            return;
          }

          if (onlyIndexChanged) {
            // Quick path — just the index changed (track advance, seek).
            // Don't recompute tracks or write 3000 tracks to DB.
            _lastPersistedIndex = playlist.index;
            state = state.copyWith(currentIndex: playlist.index);
            // Clear the pending-track id whenever the (new) active track
            // matches it. This covers track advances (incl. natural end /
            // auto-advance) and seeks. The tap callback also tries to clear
            // it, but it reads `activeTrack` synchronously right after
            // `await jumpToTrack()` — a race where the index-change stream
            // event may not have propagated yet. If that check loses the
            // race, the pending id stays set forever, which makes
            // `isPendingPlayback` true for the clicked track and shows an
            // infinite "Loading" spinner on it (in both the queue and the
            // real playlist) once the active track moves on.
            final pendingTrackId = ref.read(pendingPlaybackTrackIdProvider);
            if (pendingTrackId != null &&
                state.activeTrack?.id == pendingTrackId) {
              clearPendingPlaybackTrackId(pendingTrackId);
            }
            if (_playlistOperationId != streamSeq) return;
            await _updatePlayerState(
              AudioPlayerStateTableCompanion(
                currentIndex: Value(state.currentIndex),
                // Don't write tracks — only the index changed.
              ),
            );
            return;
          }

          // Full path — playlist content structurally changed.
          _lastPersistedPlaylistLength = playlistLength;
          _lastPersistedIndex = playlist.index;

          final tracks =
              playlist.medias.map((e) => SpotubeMedia.media(e).track).toList();

          if (!_isBatchAdding) {
            state = state.copyWith(
              tracks: tracks,
              currentIndex: playlist.index,
            );
            if (_playlistOperationId != streamSeq) return;
          } else {
            // During batch add the playlist only grows; currentIndex stays
            // put. Avoid a state.copyWith (and thus 3000 Riverpod listener
            // notifications) per added track when the index is unchanged.
            if (state.currentIndex != playlist.index) {
              state = state.copyWith(currentIndex: playlist.index);
            }
            if (_playlistOperationId != streamSeq) return;
          }
          // Clear the pending-track id regardless of batch mode. If the
          // batch (addTracks for load_remaining) starts before this event
          // is processed and clearing were gated on !_isBatchAdding, the id
          // would get stuck and jumpToTrack() would silently ignore every
          // other queue item (its guard: pendingId != track.id → return).
          final pendingTrackId = ref.read(pendingPlaybackTrackIdProvider);
          if (pendingTrackId != null &&
              state.activeTrack?.id == pendingTrackId) {
            clearPendingPlaybackTrackId(pendingTrackId);
          }

          // Skip per-event trace spam + prefetch while batch-adding a large
          // playlist (e.g. 3000 liked songs). Prefetching per added track
          // hammered YouTube -> 429 and froze the UI. Prefetch once after
          // the batch completes instead.
          if (!_isBatchAdding) {
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
            _prefetchAdjacentSources();
          }

          if (!_isBatchAdding) {
            if (_playlistOperationId != streamSeq) return;
            await _updatePlayerState(
              AudioPlayerStateTableCompanion(
                currentIndex: Value(state.currentIndex),
                tracks: Value(state.tracks),
              ),
            );
          }
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
}

final audioPlayerProvider =
    NotifierProvider<AudioPlayerNotifier, AudioPlayerState>(
  () => AudioPlayerNotifier(),
);
