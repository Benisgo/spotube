import 'dart:async';
import 'dart:math';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/audio_player/audio_player_service_provider.dart';
import 'package:spotube/provider/audio_player/state.dart';
import 'package:spotube/provider/discord_provider.dart';
import 'package:spotube/provider/history/history.dart';
import 'package:spotube/provider/metadata_plugin/core/scrobble.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/provider/multi_session/multi_session.dart';
import 'package:spotube/provider/server/sourced_track_provider.dart';
import 'package:spotube/provider/skip_segments/skip_segments.dart';
import 'package:spotube/provider/scrobbler/scrobbler.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/kv_store/kv_store.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/audio_services/audio_services.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/logger/playback_start_trace.dart';
import 'package:spotube/services/youtube_engine/yt_dlp_worker.dart';

class AudioPlayerStreamListeners {
  final Ref ref;
  /// Resolves the shared audio engine through Riverpod so it can be
  /// overridden in tests / with alternate backends.
  SpotubeAudioPlayer get audioPlayer => ref.read(audioPlayerServiceProvider);
  AudioServices? notificationService;
  String? _fadeOutTrackId;
  Future<SourcedSegments?>? _segmentsFuture;
  String? _segmentsSourceId;
  bool _skipSponsorBusy = false;
  AudioPlayerStreamListeners(this.ref) {
    AudioServices.create(ref, ref.read(audioPlayerProvider.notifier)).then(
      (value) => notificationService = value,
    );
    ref.listen(multiSessionProvider.select((state) => state.connected), (
      previous,
      next,
    ) {
      if (next == true) {
        unawaited(_stopCrossfadeAndRestoreVolume());
      }
    });

    final subscriptions = [
      subscribeToNotifications(),
      subscribeToDiscordPresence(),
      subscribeToSkipSponsor(),
      subscribeToScrobbleChanged(),
      subscribeToPosition(),
      subscribeToBufferingAndState(),
      subscribeToCrossfadeTransitions(),
      subscribeToPlayerError(),
    ];

    ref.onDispose(() {
      notificationService?.dispose();
      for (final subscription in subscriptions) {
        subscription.cancel();
      }
    });
  }

  ScrobblerNotifier get scrobbler => ref.read(scrobblerProvider.notifier);
  UserPreferences get preferences => ref.read(userPreferencesProvider);
  DiscordNotifier get discord => ref.read(discordProvider.notifier);
  AudioPlayerState get audioPlayerState => ref.read(audioPlayerProvider);
  PlaybackHistoryActions get history =>
      ref.read(playbackHistoryActionsProvider);
  double get targetVolume => KVStoreService.volume;
  bool get isInListeningRoom => ref.read(multiSessionProvider).connected;

  bool _isExpectedBackgroundPrefetchSkip(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('yt-dlp worker unavailable') ||
        message.contains('background worker deferred') ||
        message.contains('worker cancelled') ||
        message.contains('yt-dlp fallback requested');
  }

  Future<void> _stopCrossfadeAndRestoreVolume() async {
    if (!audioPlayer.isCrossfading &&
        _fadeOutTrackId == null &&
        (audioPlayer.volume - targetVolume).abs() <= 0.01) {
      return;
    }

    _fadeOutTrackId = null;
    await audioPlayer.stopCrossfadeAndRestore();

    if ((audioPlayer.volume - targetVolume).abs() > 0.01) {
      await audioPlayer.setVolume(targetVolume);
    }
  }

  StreamSubscription subscribeToNotifications() {
    return audioPlayer.playlistStream.listen((mpvPlaylist) {
      try {
        if (audioPlayerState.activeTrack == null) return;
        notificationService?.addTrack(audioPlayerState.activeTrack!);
      } catch (e, stack) {
        AppLogger.reportError(e, stack);
      }
    });
  }

  StreamSubscription subscribeToDiscordPresence() {
    return audioPlayer.playlistStream.listen((mpvPlaylist) {
      try {
        if (audioPlayerState.activeTrack == null) return;
        discord.schedulePresenceUpdate(audioPlayerState.activeTrack!);
      } catch (e, stack) {
        AppLogger.reportError(e, stack);
      }
    });
  }

  StreamSubscription subscribeToSkipSponsor() {
    return audioPlayer.positionStream.listen((position) async {
      if (!audioPlayer.isPlaying) return;
      if (_skipSponsorBusy) return;
      try {
        if (position < const Duration(seconds: 3)) {
          return;
        }

        final activeTrack = audioPlayerState.activeTrack;
        if (activeTrack == null || activeTrack is SpotubeLocalTrackObject) {
          return;
        }

        if (_segmentsSourceId != activeTrack.id || _segmentsFuture == null) {
          _segmentsSourceId = activeTrack.id;
          _segmentsFuture = ref.read(segmentProvider.future);
        }

        _skipSponsorBusy = true;
        final currentSegments = await _segmentsFuture;

        if (currentSegments?.segments.isNotEmpty != true) {
          return;
        }

        for (final segment in currentSegments!.segments) {
          final seconds = position.inSeconds;

          if (seconds < segment.start || seconds >= segment.end) continue;

          await audioPlayer.seek(Duration(seconds: segment.end + 1));
        }
      } catch (e, stack) {
        AppLogger.reportError(e, stack);
      } finally {
        _skipSponsorBusy = false;
      }
    });
  }

  StreamSubscription subscribeToScrobbleChanged() {
    String? lastScrobbled;
    return audioPlayer.positionStream.listen((position) async {
      if (!audioPlayer.isPlaying) return;
      try {
        final uid = audioPlayerState.activeTrack is SpotubeLocalTrackObject
            ? (audioPlayerState.activeTrack as SpotubeLocalTrackObject).path
            : audioPlayerState.activeTrack?.id;

        /// According to Listenbrainz and Last.fm, a scrobble should be sent
        /// after 4 minutes of listening or 50% of the track duration,
        /// whichever is less.
        final minimumListenTime = min(audioPlayer.duration.inSeconds ~/ 2, 240);

        if (audioPlayerState.activeTrack == null ||
            lastScrobbled == uid ||
            position.inSeconds < minimumListenTime ||
            audioPlayer.duration == Duration.zero ||
            position == Duration.zero) {
          return;
        }

        scrobbler.scrobble(audioPlayerState.activeTrack!);
        ref
            .read(metadataPluginScrobbleProvider.notifier)
            .scrobble(audioPlayerState.activeTrack!);
        lastScrobbled = uid;

        /// The [Track] from Playlist.getTracks doesn't contain artist images
        /// so we need to fetch them from the API
        var activeTrack = audioPlayerState.activeTrack!;
        if (activeTrack.artists.any((a) => a.images == null)) {
          final metadataPlugin = await ref.read(metadataPluginProvider.future);
          final artists = await Future.wait(
            activeTrack.artists
                .map((artist) => metadataPlugin!.artist.getArtist(artist.id)),
          );
          activeTrack = activeTrack.copyWith(
            artists: artists
                .map((e) => SpotubeSimpleArtistObject.fromJson(e.toJson()))
                .toList(),
          );
        }

        await history.addTrack(activeTrack);
      } catch (e, stack) {
        AppLogger.reportError(e, stack);
      }
    });
  }

  StreamSubscription subscribeToPosition() {
    String lastTrack = ""; // used to prevent multiple calls to the same track
    return audioPlayer.positionStream.listen((event) async {
      if (!audioPlayer.isPlaying) return;
      final percentProgress =
          (event.inSeconds / max(audioPlayer.duration.inSeconds, 1)) * 100;
      try {
        if (percentProgress < 80 ||
            audioPlayerState.currentIndex == -1 ||
            audioPlayerState.currentIndex ==
                audioPlayerState.tracks.length - 1) {
          return;
        }
        final nextTrack = audioPlayerState.tracks
            .elementAtOrNull(audioPlayerState.currentIndex + 1);

        if (nextTrack == null ||
            lastTrack == nextTrack.id ||
            nextTrack is SpotubeLocalTrackObject) {
          return;
        }

        try {
          final fullTrack = nextTrack as SpotubeFullTrackObject;
          if (YtDlpWorkerClient.shouldDeferBackgroundWork) {
            lastTrack = fullTrack.id;
            return;
          }
          // Mark before awaiting so repeated near-end position events don't
          // enqueue the same background warmup over and over.
          lastTrack = fullTrack.id;
          await YtDlpExecutionContext.runBackground(() async {
            final sourcedTrack =
                await ref.read(sourcedTrackProvider(fullTrack).future);
            if (!sourcedTrack.hasFreshValidatedStream) {
              await ref
                  .read(sourcedTrackProvider(fullTrack).notifier)
                  .refreshStreamingUrl();
            }
          }, cancelGroup: 'position-prefetch:${fullTrack.id}');
        } finally {}
      } catch (e, stack) {
        if (_isExpectedBackgroundPrefetchSkip(e)) {
          return;
        }
        AppLogger.reportError(e, stack);
      }
    });
  }

  StreamSubscription subscribeToBufferingAndState() {
    final bufferingSubscription =
        audioPlayer.bufferingStream.listen((buffering) {
      final activeTrackId = audioPlayerState.activeTrack?.id;
      if (activeTrackId == null) return;
      PlaybackStartTrace.markTrack(
        activeTrackId,
        buffering ? 'player.buffering_true' : 'player.buffering_false',
      );
    });

    final playerStateSubscription =
        audioPlayer.playerStateStream.listen((state) {
      final activeTrackId = audioPlayerState.activeTrack?.id;
      if (activeTrackId == null) return;
      PlaybackStartTrace.markTrack(
        activeTrackId,
        'player.state.${state.name}',
      );
    });

    return _CompositeSubscription([
      bufferingSubscription,
      playerStateSubscription,
    ]);
  }

  StreamSubscription subscribeToCrossfadeTransitions() {
    final positionSubscription =
        audioPlayer.positionStream.listen((position) async {
      try {
        final preferences = ref.read(userPreferencesProvider);
        if (!preferences.crossfadeTracks || isInListeningRoom) {
          await _stopCrossfadeAndRestoreVolume();
          return;
        }

        if (!audioPlayer.isPlaying ||
            audioPlayer.duration == Duration.zero ||
            audioPlayerState.currentIndex < 0 ||
            audioPlayerState.currentIndex >=
                audioPlayerState.tracks.length - 1) {
          await _stopCrossfadeAndRestoreVolume();
          return;
        }

        final activeTrack = audioPlayerState.activeTrack;
        if (activeTrack == null) return;

        final fadeDuration = Duration(
          seconds: preferences.crossfadeDurationSeconds,
        );
        final remaining = audioPlayer.duration - position;

        if (remaining <= Duration.zero ||
            remaining > fadeDuration ||
            _fadeOutTrackId == activeTrack.id) {
          return;
        }

        _fadeOutTrackId = activeTrack.id;
        final crossfadeStarted = await audioPlayer.startCrossfadeToNext(
          remaining,
        );
        if (!crossfadeStarted) {
          _fadeOutTrackId = null;
        }
      } catch (e, stack) {
        AppLogger.reportError(e, stack);
      }
    });

    final indexSubscription = audioPlayer.currentIndexChangedStream.listen((
      index,
    ) async {
      try {
        _fadeOutTrackId = null;
      } catch (e, stack) {
        AppLogger.reportError(e, stack);
      }
    });

    return _CompositeSubscription([positionSubscription, indexSubscription]);
  }

  StreamSubscription subscribeToPlayerError() {
    return audioPlayer.errorStream.listen((event) {
      final activeTrackId = audioPlayerState.activeTrack?.id;
      if (activeTrackId != null) {
        PlaybackStartTrace.failTrack(
          activeTrackId,
          'player.error',
          data: {'error': event},
        );
      }
      ref.read(audioPlayerProvider.notifier).clearPendingPlaybackTrackId();
    });
  }
}

class _CompositeSubscription implements StreamSubscription<void> {
  final List<StreamSubscription> _subscriptions;

  const _CompositeSubscription(this._subscriptions);

  @override
  Future<void> cancel() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
  }

  @override
  void onData(void Function(void data)? handleData) {}

  @override
  void onDone(void Function()? handleDone) {}

  @override
  void onError(Function? handleError) {}

  @override
  void pause([Future<void>? resumeSignal]) {
    for (final subscription in _subscriptions) {
      subscription.pause(resumeSignal);
    }
  }

  @override
  void resume() {
    for (final subscription in _subscriptions) {
      subscription.resume();
    }
  }

  @override
  bool get isPaused =>
      _subscriptions.every((subscription) => subscription.isPaused);

  @override
  Future<E> asFuture<E>([E? futureValue]) {
    return Future.wait(
      _subscriptions.map((subscription) => subscription.asFuture<void>()),
    ).then((_) => futureValue as E);
  }
}

final audioPlayerStreamListenersProvider =
    Provider<AudioPlayerStreamListeners>(AudioPlayerStreamListeners.new);
