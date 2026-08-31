import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:smtc_windows/smtc_windows.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/audio_player/audio_player_service_provider.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/audio_player/playback_state.dart';
import 'package:spotube/services/logger/logger.dart';

class WindowsAudioService {
  static const _minSmtcPositionPushInterval = Duration(seconds: 5);

  /// Resolves the shared audio engine through Riverpod.
  SpotubeAudioPlayer get audioPlayer => ref.read(audioPlayerServiceProvider);
  final SMTCWindows smtc;
  final Ref ref;
  final AudioPlayerNotifier audioPlayerNotifier;

  final subscriptions = <StreamSubscription>[];
  Duration _lastReportedPosition = Duration.zero;
  DateTime _lastReportedAt = DateTime.now();
  bool _updatingPosition = false;
  Duration _lastReportedDuration = Duration.zero;
  bool _updatingDuration = false;
  AudioPlaybackState? _lastReportedPlaybackState;
  bool _updatingPlaybackState = false;
  DateTime? _lastPositionPushAt;

  WindowsAudioService(this.ref, this.audioPlayerNotifier)
      : smtc = SMTCWindows(
          config: const SMTCConfig(
            playEnabled: true,
            pauseEnabled: true,
            stopEnabled: true,
            nextEnabled: true,
            prevEnabled: true,
            fastForwardEnabled: false,
            rewindEnabled: false,
          ),
        ) {
    unawaited(_safeSmtcCall(
      () => smtc.setPlaybackStatus(PlaybackStatus.stopped),
      'setPlaybackStatus(stopped)',
    ));

    // ignore: cancel_subscriptions — added to subscriptions, cancelled in dispose().
    final buttonStream = smtc.buttonPressStream.listen((event) {
      switch (event) {
        case PressedButton.play:
          audioPlayer.resume();
          break;
        case PressedButton.pause:
          audioPlayer.pause();
          break;
        case PressedButton.next:
          audioPlayer.skipToNext();
          break;
        case PressedButton.previous:
          audioPlayer.skipToPrevious();
          break;
        case PressedButton.stop:
          audioPlayerNotifier.stop();
          break;
        default:
          break;
      }
    });

    // ignore: cancel_subscriptions — added to subscriptions, cancelled in dispose().
    final shuffleRequestStream = smtc.shuffleChangeStream.listen((enabled) {
      audioPlayer.setShuffle(enabled);
    });

    // ignore: cancel_subscriptions — added to subscriptions, cancelled in dispose().
    final repeatRequestStream = smtc.repeatModeChangeStream.listen((mode) {
      audioPlayer.setLoopMode(switch (mode) {
        RepeatMode.none => PlaylistMode.none,
        RepeatMode.track => PlaylistMode.single,
        RepeatMode.list => PlaylistMode.loop,
      });
    });

    // ignore: cancel_subscriptions — added to subscriptions, cancelled in dispose().
    final playerStateStream =
        audioPlayer.playerStateStream.listen((state) async {
      if (_updatingPlaybackState || _lastReportedPlaybackState == state) {
        return;
      }

      _updatingPlaybackState = true;
      try {
        switch (state) {
          case AudioPlaybackState.playing:
            await _safeSmtcCall(
              () => smtc.setPlaybackStatus(PlaybackStatus.playing),
              'setPlaybackStatus(playing)',
            );
            _lastReportedAt = DateTime.now();
            break;
          case AudioPlaybackState.paused:
            await _safeSmtcCall(
              () => smtc.setPlaybackStatus(PlaybackStatus.paused),
              'setPlaybackStatus(paused)',
            );
            await _pushPositionToSmtc(audioPlayer.position, force: true);
            _lastReportedAt = DateTime.now();
            break;
          case AudioPlaybackState.stopped:
            await _safeSmtcCall(
              () => smtc.setPlaybackStatus(PlaybackStatus.stopped),
              'setPlaybackStatus(stopped)',
            );
            break;
          case AudioPlaybackState.completed:
            await _safeSmtcCall(
              () => smtc.setPlaybackStatus(PlaybackStatus.changing),
              'setPlaybackStatus(changing)',
            );
            break;
          default:
            return;
        }
        _lastReportedPlaybackState = state;
      } finally {
        _updatingPlaybackState = false;
      }
    });

    // ignore: cancel_subscriptions — added to subscriptions, cancelled in dispose().
    final positionStream = audioPlayer.positionStream.listen((pos) async {
      if (_updatingPosition) return;

      await _pushPositionToSmtc(pos);
    });

    // ignore: cancel_subscriptions — added to subscriptions, cancelled in dispose().
    final durationStream = audioPlayer.durationStream.listen((duration) async {
      if (_updatingDuration || duration == Duration.zero) {
        return;
      }
      if ((duration - _lastReportedDuration).inMilliseconds.abs() < 1000) {
        return;
      }

      _updatingDuration = true;
      try {
        await _safeSmtcCall(
          () => smtc.setEndTime(duration),
          'setEndTime',
        );
        _lastReportedDuration = duration;
      } finally {
        _updatingDuration = false;
      }
    });

    // Sync app shuffle/repeat state to SMTC when it changes
    ref.listen(audioPlayerProvider, (prev, next) {
      if (prev?.shuffled != next.shuffled) {
        unawaited(_safeSmtcCall(
          () => smtc.setShuffleEnabled(next.shuffled),
          'setShuffleEnabled',
        ));
      }
      if (prev?.loopMode != next.loopMode) {
        unawaited(_safeSmtcCall(
          () => smtc.setRepeatMode(switch (next.loopMode) {
            PlaylistMode.none => RepeatMode.none,
            PlaylistMode.single => RepeatMode.track,
            PlaylistMode.loop => RepeatMode.list,
          }),
          'setRepeatMode',
        ));
      }
    });

    subscriptions.addAll([
      buttonStream,
      shuffleRequestStream,
      repeatRequestStream,
      playerStateStream,
      positionStream,
      durationStream,
    ]);
  }

  Future<void> addTrack(SpotubeTrackObject track) async {
    final thumbnail = track.album.images.isNotEmpty
        ? track.album.images.asUrlString(
            placeholder: ImagePlaceholder.albumArt,
          )
        : null;

    await smtc.updateMetadata(
      MusicMetadata(
        title: track.name,
        albumArtist: track.artists.firstOrNull?.name ?? "Unknown",
        artist: track.artists.asString(),
        album: track.album.name,
        thumbnail: thumbnail,
      ),
    );

    // Sync current shuffle/repeat state
    final state = ref.read(audioPlayerProvider);
    await _safeSmtcCall(
      () => smtc.setShuffleEnabled(state.shuffled),
      'setShuffleEnabled',
    );
    await _safeSmtcCall(
      () => smtc.setRepeatMode(switch (state.loopMode) {
        PlaylistMode.none => RepeatMode.none,
        PlaylistMode.single => RepeatMode.track,
        PlaylistMode.loop => RepeatMode.list,
      }),
      'setRepeatMode',
    );
  }

  void dispose() {
    smtc.disableSmtc();
    smtc.dispose();
    for (var element in subscriptions) {
      element.cancel();
    }
  }

  Future<void> _pushPositionToSmtc(
    Duration pos, {
    bool force = false,
  }) async {
    final now = DateTime.now();
    final expectedPos = audioPlayer.isPlaying
        ? _lastReportedPosition + now.difference(_lastReportedAt)
        : _lastReportedPosition;
    final recentlyPushed = _lastPositionPushAt != null &&
        now.difference(_lastPositionPushAt!) < _minSmtcPositionPushInterval;

    if (!force) {
      if ((pos - expectedPos).inMilliseconds.abs() < 1500) {
        return;
      }
      if (recentlyPushed) {
        return;
      }
    }

    _updatingPosition = true;
    try {
      await _safeSmtcCall(
        () => smtc.setPosition(pos),
        'setPosition',
      );
      _lastReportedPosition = pos;
      _lastReportedAt = now;
      _lastPositionPushAt = now;
    } finally {
      _updatingPosition = false;
    }
  }

  Future<void> _safeSmtcCall(
    Future<void> Function() action,
    String label,
  ) async {
    try {
      await action();
    } catch (error, stackTrace) {
      await AppLogger.reportError(
        error,
        stackTrace,
        'SMTC call failed: $label',
      );
    }
  }
}
