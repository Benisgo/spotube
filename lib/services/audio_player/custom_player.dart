import 'dart:async';
import 'package:spotube/services/logger/logger.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_broadcasts/flutter_broadcasts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:audio_session/audio_session.dart';
// ignore: implementation_imports
import 'package:spotube/services/audio_player/playback_state.dart';
import 'package:spotube/utils/platform.dart';

/// MediaKit [Player] by default doesn't have a state stream.
/// This class adds a state stream to the [Player] class.
class CustomPlayer extends Player {
  final StreamController<AudioPlaybackState> _playerStateStream;

  late final List<StreamSubscription> _subscriptions;

  int _androidAudioSessionId = 0;
  String _packageName = "";
  AndroidAudioManager? _androidAudioManager;

  CustomPlayer({super.configuration})
      : _playerStateStream = StreamController.broadcast() {
    if (kIsAndroid) {
      nativePlayer.setProperty("network-timeout", "3");
      nativePlayer.setProperty(
        "demuxer-max-bytes",
        (10 * 1024 * 1024).toString(), // 10MB — cache entire song
      );
      nativePlayer.setProperty(
        "demuxer-max-back-bytes",
        (10 * 1024 * 1024).toString(), // 10MB backward seek buffer
      );
      // Read the whole song ahead so the seekbar is fully highlighted and
      // the proxy downloads the full file -> small songs get cached after
      // a single play. Previously cache-secs=2 meant mpv only read ~2s
      // ahead, so the cache file rarely completed.
      nativePlayer.setProperty("cache-secs", "600"); // 10 min — full song cache
      nativePlayer.setProperty("cache-pause-initial", "no");
      nativePlayer.setProperty(
          "cache-pause", "no"); // don't pause while filling
    } else if (kIsWindows) {
      nativePlayer.setProperty("network-timeout", "5");
      nativePlayer.setProperty(
        "demuxer-max-bytes",
        (10 * 1024 * 1024).toString(), // 10MB — cache entire song
      );
      nativePlayer.setProperty(
        "demuxer-max-back-bytes",
        (10 * 1024 * 1024).toString(), // 10MB backward seek buffer
      );
      nativePlayer.setProperty("cache-secs", "600"); // 10 min — full song cache
      nativePlayer.setProperty(
          "cache-pause", "no"); // don't pause while filling
      // Disable video output entirely — audio-only app
      nativePlayer.setProperty("vo", "null");
      nativePlayer.setProperty("video", "no");
      // Use wasapi for low-overhead audio on Windows
      nativePlayer.setProperty("ao", "wasapi");
      // No hardware decoding needed for audio-only
      nativePlayer.setProperty("hwdec", "no");
      // Reduce mpv event rate to prevent Windows task runner flooding.
      // mpv fires time-pos/percent-pos events at video frame rate which
      // overwhelms Flutter's Windows message loop, freezing the UI.
      nativePlayer.setProperty(
          "video-sync", "audio"); // sync to audio clock only
      nativePlayer.setProperty(
          "video-output", "no"); // completely disable video output
      nativePlayer.setProperty("audio-buffer", "0.050"); // small audio buffer
      nativePlayer.setProperty("keep-open", "no"); // no post-EOF idle state
    } else {
      nativePlayer.setProperty("network-timeout", "120");
      nativePlayer.setProperty(
        "demuxer-max-bytes",
        (4 * 1024 * 1024).toString(),
      );
      nativePlayer.setProperty(
        "demuxer-max-back-bytes",
        (1 * 1024 * 1024).toString(),
      );
      // Disable video output entirely — audio-only app
      nativePlayer.setProperty("vo", "null");
      nativePlayer.setProperty("video", "no");
      nativePlayer.setProperty("hwdec", "no");
    }

    _subscriptions = [
      stream.buffering.listen((buffering) {
        if (buffering) {
          _playerStateStream.add(AudioPlaybackState.buffering);
        }
      }),
      stream.playing.listen((playing) {
        if (playing) {
          _playerStateStream.add(AudioPlaybackState.playing);
        } else {
          _playerStateStream.add(AudioPlaybackState.paused);
        }
      }),
      stream.completed.listen((isCompleted) async {
        if (!isCompleted) return;
        _playerStateStream.add(AudioPlaybackState.completed);
      }),
      stream.playlist.listen((event) {
        if (event.medias.isEmpty) {
          _playerStateStream.add(AudioPlaybackState.stopped);
        }
      }),
      stream.error.listen((event) {
        AppLogger.trace('[MediaKitError] $event');
      })
    ];
    PackageInfo.fromPlatform().then((packageInfo) {
      _packageName = packageInfo.packageName;
    });
    if (kIsAndroid) {
      _androidAudioManager = AndroidAudioManager();
      AudioSession.instance.then((s) async {
        _androidAudioSessionId =
            await _androidAudioManager!.generateAudioSessionId();
        notifyAudioSessionUpdate(true);

        await nativePlayer.setProperty(
          "audiotrack-session-id",
          _androidAudioSessionId.toString(),
        );
        await nativePlayer.setProperty("ao", "audiotrack,opensles,");
      });
    }
  }

  Future<void> notifyAudioSessionUpdate(bool active) async {
    if (kIsAndroid) {
      sendBroadcast(
        BroadcastMessage(
          name: active
              ? "android.media.action.OPEN_AUDIO_EFFECT_CONTROL_SESSION"
              : "android.media.action.CLOSE_AUDIO_EFFECT_CONTROL_SESSION",
          data: {
            "android.media.extra.AUDIO_SESSION": _androidAudioSessionId,
            "android.media.extra.PACKAGE_NAME": _packageName
          },
        ),
      );
    }
  }

  bool get shuffled => state.shuffle;

  Stream<AudioPlaybackState> get playerStateStream => _playerStateStream.stream;
  Stream<bool> get shuffleStream => stream.shuffle;
  Stream<int> get indexChangeStream {
    int oldIndex = state.playlist.index;
    return stream.playlist.map((event) => event.index).where((newIndex) {
      if (newIndex != oldIndex) {
        oldIndex = newIndex;
        return true;
      }
      return false;
    });
  }

  @override
  Future<void> setShuffle(bool shuffle) async {
    await super.setShuffle(shuffle);
  }

  @override
  Future<void> stop() async {
    await super.stop();

    _playerStateStream.add(AudioPlaybackState.stopped);
  }

  @override
  Future<void> dispose() async {
    for (var element in _subscriptions) {
      element.cancel();
    }
    await notifyAudioSessionUpdate(false);
    return super.dispose();
  }

  NativePlayer get nativePlayer => platform as NativePlayer;

  Future<void> insert(int index, Media media) async {
    final addedMediaCompleter = Completer<int>();
    final playlistStream = stream.playlist.listen(
      (event) {
        final mediaAddedIndex =
            event.medias.indexWhere((m) => m.uri == media.uri);
        if (mediaAddedIndex != -1 && !addedMediaCompleter.isCompleted) {
          addedMediaCompleter.complete(mediaAddedIndex);
        }
      },
    );
    try {
      await add(media);
      final mediaAddedIndex = await addedMediaCompleter.future;
      await move(mediaAddedIndex, index);
    } finally {
      playlistStream.cancel();
    }
  }

  bool _normalizationEnabled = false;

  Future<void> setAudioNormalization(bool normalize) async {
    _normalizationEnabled = normalize;
    try {
      if (normalize) {
        try {
          await nativePlayer.setProperty(
              'af', 'dynaudnorm=g=5:f=250:r=0.9:p=0.5');
        } catch (_) {
          // If dynaudnorm audio filter is missing/unsupported by libmpv build,
          // clear 'af' so mpv does not fail stream opening.
          await nativePlayer.setProperty('af', '');
        }
      } else {
        await nativePlayer.setProperty('af', '');
      }
    } catch (e, stack) {
      AppLogger.reportError(e, stack, 'setAudioNormalization failed');
    }
  }

  Future<void> reapplyNormalizationIfNeeded() async {
    if (!_normalizationEnabled) return;
    try {
      await nativePlayer.setProperty('af', 'dynaudnorm=g=5:f=250:r=0.9:p=0.5');
    } catch (_) {
      try {
        await nativePlayer.setProperty('af', '');
      } catch (_) {}
    }
  }

  Future<void> setDemuxerBufferSize(int sizeInBytes) async {
    await nativePlayer.setProperty('demuxer-max-bytes', sizeInBytes.toString());
    await nativePlayer.setProperty(
      'demuxer-max-back-bytes',
      sizeInBytes.toString(),
    );
  }

  Future<void> primeWindowsPipeline() async {
    if (!kIsWindows) return;
    final currentVol = state.volume;
    if (currentVol <= 0) return;
    await setVolume(0);
    await play();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await setVolume(currentVol);
  }
}
