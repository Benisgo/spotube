import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:smtc_windows/smtc_windows.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/audio_player/playback_state.dart';

class WindowsAudioService {
  final SMTCWindows smtc;
  final Ref ref;
  final AudioPlayerNotifier audioPlayerNotifier;

  final subscriptions = <StreamSubscription>[];
  Duration _lastReportedPosition = Duration.zero;
  bool _updatingPosition = false;
  Duration _lastReportedDuration = Duration.zero;
  bool _updatingDuration = false;
  AudioPlaybackState? _lastReportedPlaybackState;
  bool _updatingPlaybackState = false;

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
    smtc.setPlaybackStatus(PlaybackStatus.stopped);
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

    final playerStateStream =
        audioPlayer.playerStateStream.listen((state) async {
      if (_updatingPlaybackState || _lastReportedPlaybackState == state) {
        return;
      }

      _updatingPlaybackState = true;
      try {
        switch (state) {
          case AudioPlaybackState.playing:
            await smtc.setPlaybackStatus(PlaybackStatus.playing);
            break;
          case AudioPlaybackState.paused:
            await smtc.setPlaybackStatus(PlaybackStatus.paused);
            break;
          case AudioPlaybackState.stopped:
            await smtc.setPlaybackStatus(PlaybackStatus.stopped);
            break;
          case AudioPlaybackState.completed:
            await smtc.setPlaybackStatus(PlaybackStatus.changing);
            break;
          default:
            return;
        }
        _lastReportedPlaybackState = state;
      } finally {
        _updatingPlaybackState = false;
      }
    });

    final positionStream = audioPlayer.positionStream.listen((pos) async {
      if (_updatingPosition ||
          (pos - _lastReportedPosition).inMilliseconds.abs() < 1000) {
        return;
      }

      _updatingPosition = true;
      try {
        await smtc.setPosition(pos);
        _lastReportedPosition = pos;
      } finally {
        _updatingPosition = false;
      }
    });

    final durationStream = audioPlayer.durationStream.listen((duration) async {
      if (_updatingDuration || duration == Duration.zero) {
        return;
      }
      if ((duration - _lastReportedDuration).inMilliseconds.abs() < 1000) {
        return;
      }

      _updatingDuration = true;
      try {
        await smtc.setEndTime(duration);
        _lastReportedDuration = duration;
      } finally {
        _updatingDuration = false;
      }
    });

    subscriptions.addAll([
      buttonStream,
      playerStateStream,
      positionStream,
      durationStream,
    ]);
  }

  Future<void> addTrack(SpotubeTrackObject track) async {
    await smtc.updateMetadata(
      MusicMetadata(
        title: track.name,
        albumArtist: track.artists.firstOrNull?.name ?? "Unknown",
        artist: track.artists.asString(),
        album: track.album.name,
      ),
    );
  }

  void dispose() {
    smtc.disableSmtc();
    smtc.dispose();
    for (var element in subscriptions) {
      element.cancel();
    }
  }
}
