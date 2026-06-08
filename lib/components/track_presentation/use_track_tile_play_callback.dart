import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:spotube/components/dialogs/select_device_dialog.dart';
import 'package:spotube/components/track_presentation/presentation_props.dart';
import 'package:spotube/components/track_presentation/presentation_state.dart';
import 'package:spotube/extensions/list.dart';

import 'package:spotube/models/connect/connect.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/connect/connect.dart';
import 'package:spotube/provider/history/history.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/logger/playback_start_trace.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/youtube_engine/yt_dlp_worker.dart';

Future<void> Function(SpotubeTrackObject track, int index)
    useTrackTilePlayCallback(
  WidgetRef ref,
) {
  const primeAwaitBudget = Duration(seconds: 7);
  final context = useContext();
  final options = TrackPresentationOptions.of(context);
  final playlist = ref.watch(audioPlayerProvider);
  final playlistNotifier = ref.watch(audioPlayerProvider.notifier);
  final historyNotifier = ref.watch(playbackHistoryActionsProvider);

  final isActive = useMemoized(
    () => playlist.collections.contains(options.collectionId),
    [playlist.collections, options.collectionId],
  );

  final onTapTrackTile =
      useCallback((SpotubeTrackObject track, int index) async {
    final state = ref.read(presentationStateProvider(options.collection));
    final notifier =
        ref.read(presentationStateProvider(options.collection).notifier);

    if (state.selectedTracks.isNotEmpty) {
      if (state.selectedTracks.contains(track)) {
        notifier.deselectTrack(track);
      } else {
        notifier.selectTrack(track);
      }
      return;
    }

    final isRemoteDevice = await showSelectDeviceDialog(context, ref);
    if (isRemoteDevice == null) return;

    if (isRemoteDevice) {
      final remotePlayback = ref.read(connectProvider.notifier);
      final remoteQueue = ref.read(queueProvider);
      if (remoteQueue.collections.contains(options.collectionId) ||
          remoteQueue.tracks.any((s) => s.id == track.id)) {
        await playlistNotifier.jumpToTrack(track);
      } else {
        final tracks = await options.pagination.onFetchAll();
        final actualIndex = tracks.indexWhere((t) => t.id == track.id);
        final safeIndex = actualIndex >= 0 ? actualIndex : index;
        await remotePlayback.load(
          options.collection is SpotubeSimpleAlbumObject
              ? WebSocketLoadEventData.album(
                  tracks: tracks,
                  collection: options.collection as SpotubeSimpleAlbumObject,
                  initialIndex: safeIndex,
                )
              : WebSocketLoadEventData.playlist(
                  tracks: tracks,
                  collection: options.collection as SpotubeSimplePlaylistObject,
                  initialIndex: safeIndex,
                ),
        );
      }
    } else {
      PlaybackStartTrace.begin(
        track.id,
        trigger: 'track_tile_tap',
        data: {
          'index': index,
          'collectionId': options.collectionId,
          'isActiveCollection': isActive,
        },
      );
      YtDlpWorkerClient.notifyForegroundPlaybackStart();
      playlistNotifier.setPendingPlaybackTrackId(track.id);
      PlaybackStartTrace.markTrack(track.id, 'pending_track_set');
      Future<void>? primeFuture;
      if (track is SpotubeFullTrackObject) {
        PlaybackStartTrace.markTrack(track.id, 'prime_requested');
        primeFuture = playlistNotifier.primeTrackPlayback(track);
      }

      final hasActiveLocalSource =
          audioPlayer.hasSource && playlist.currentIndex >= 0;
      final isTrackQueued =
          playlist.tracks.containsBy(track, (a) => a.id);
      final canJumpInCurrentQueue = hasActiveLocalSource && isTrackQueued;

      try {
        if (primeFuture != null && canJumpInCurrentQueue) {
          PlaybackStartTrace.markTrack(
            track.id,
            'prime_await.start',
            data: {'budgetMs': primeAwaitBudget.inMilliseconds},
          );
          try {
            await primeFuture.timeout(primeAwaitBudget);
            PlaybackStartTrace.markTrack(track.id, 'prime_await.done');
          } on TimeoutException {
            PlaybackStartTrace.markTrack(track.id, 'prime_await.timeout');
          }
        } else if (primeFuture != null) {
          PlaybackStartTrace.markTrack(track.id, 'prime_await.skipped');
        }

        if (canJumpInCurrentQueue) {
          PlaybackStartTrace.markTrack(
            track.id,
            'jump_to_existing_queue.start',
          );
          await playlistNotifier.jumpToTrack(track);
          PlaybackStartTrace.markTrack(track.id, 'jump_to_existing_queue.done');
        } else {
          final initialTracks = options.tracks;
          if (initialTracks.isEmpty) {
            PlaybackStartTrace.failTrack(
              track.id,
              'load.aborted_empty_initial_tracks',
            );
            playlistNotifier.clearPendingPlaybackTrackId(track.id);
            return;
          }

          final actualIndex = initialTracks.indexWhere((t) => t.id == track.id);
          final safeIndex = actualIndex >= 0 ? actualIndex : index;

          PlaybackStartTrace.markTrack(
            track.id,
            'load_playlist.start',
            data: {'initialTrackCount': initialTracks.length},
          );
          await playlistNotifier.load(
            initialTracks,
            initialIndex: safeIndex,
            autoPlay: true,
          );
          PlaybackStartTrace.markTrack(track.id, 'load_playlist.done');
          playlistNotifier.addCollection(options.collectionId);
          if (options.collection is SpotubeSimpleAlbumObject) {
            historyNotifier
                .addAlbums([options.collection as SpotubeSimpleAlbumObject]);
          } else {
            historyNotifier.addPlaylists(
                [options.collection as SpotubeSimplePlaylistObject]);
          }

          if (options.pagination.hasNextPage) {
            unawaited(
              () async {
                try {
                  PlaybackStartTrace.markTrack(
                    track.id,
                    'load_remaining_tracks.start',
                  );
                  final allTracks = await options.pagination.onFetchAll();
                  final remainingTracks =
                      allTracks.skip(initialTracks.length).toList();
                  if (remainingTracks.isNotEmpty) {
                    await playlistNotifier.addTracks(remainingTracks);
                  }
                  PlaybackStartTrace.markTrack(
                    track.id,
                    'load_remaining_tracks.done',
                    data: {'remainingTrackCount': remainingTracks.length},
                  );
                } catch (error, stack) {
                  PlaybackStartTrace.markTrack(
                    track.id,
                    'load_remaining_tracks.failed',
                    data: {'error': error.toString()},
                  );
                  await AppLogger.reportError(
                    error,
                    stack,
                    "Failed to fetch remaining tracks for ${options.collectionId}",
                  );
                }
              }(),
            );
          }
        }
      } catch (error) {
        PlaybackStartTrace.failTrack(
          track.id,
          'playback_request.failed',
          data: {'error': error.toString()},
        );
        playlistNotifier.clearPendingPlaybackTrackId(track.id);
        rethrow;
      }

      final activeTrackId = ref.read(audioPlayerProvider).activeTrack?.id;
      if (activeTrackId == track.id) {
        PlaybackStartTrace.markTrack(track.id, 'active_track_matched');
        playlistNotifier.clearPendingPlaybackTrackId(track.id);
      }
    }
  }, [isActive, playlist, options, playlistNotifier, historyNotifier]);

  return onTapTrackTile;
}
