import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:media_kit/media_kit.dart' as mk;
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/services/audio_player/custom_player.dart';
import 'package:spotube/services/audio_player/playback_state.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/utils/platform.dart';

part 'audio_players_streams_mixin.dart';
part 'audio_player_impl.dart';

class SpotubeMedia extends mk.Media {
  static int serverPort = 0;

  static String get _host =>
      kIsWindows ? "localhost" : InternetAddress.loopbackIPv4.address;

  final SpotubeTrackObject track;
  SpotubeMedia(this.track)
      : assert(
          track is SpotubeLocalTrackObject || track is SpotubeFullTrackObject,
          "Track must be a either a local track or a full track object with ISRC",
        ),
        super(
          track is SpotubeLocalTrackObject
              ? track.path
              : "http://$_host:$serverPort/stream/${track.id}",
          extras: track.toJson(),
        );

  factory SpotubeMedia.media(Media media) {
    assert(media.extras != null, "[Media] must have extra metadata set");
    return SpotubeMedia(SpotubeTrackObject.fromJson(media.extras!));
  }
}

abstract class AudioPlayerInterface {
  late final CustomPlayer _primaryPlayer;
  late final CustomPlayer _secondaryPlayer;

  final _durationStreamController = StreamController<Duration>.broadcast();
  final _positionStreamController = StreamController<Duration>.broadcast();
  final _bufferedPositionStreamController =
      StreamController<Duration>.broadcast();
  final _completedStreamController = StreamController<void>.broadcast();
  final _playingStreamController = StreamController<bool>.broadcast();
  final _shuffledStreamController = StreamController<bool>.broadcast();
  final _loopModeStreamController = StreamController<PlaylistMode>.broadcast();
  final _volumeStreamController = StreamController<double>.broadcast();
  final _bufferingStreamController = StreamController<bool>.broadcast();
  final _playerStateStreamController =
      StreamController<AudioPlaybackState>.broadcast();
  final _currentIndexStreamController = StreamController<int>.broadcast();
  final _activeSourceStreamController = StreamController<String>.broadcast();
  final _devicesStreamController =
      StreamController<List<mk.AudioDevice>>.broadcast();
  final _selectedDeviceStreamController =
      StreamController<mk.AudioDevice>.broadcast();
  final _errorStreamController = StreamController<String>.broadcast();
  final _playlistStreamController = StreamController<mk.Playlist>.broadcast();

  final List<StreamSubscription> _playerSubscriptions = [];

  mk.Playlist _playlist = const mk.Playlist([]);
  int _currentIndex = -1;
  bool _isPlaying = false;
  bool _isShuffled = false;
  PlaylistMode _loopMode = PlaylistMode.none;
  double _targetVolume = 1.0;
  bool _primaryPlayerActive = true;
  bool _isCrossfading = false;
  Timer? _crossfadeTimer;
  Timer? _crossfadeHandoffTimer;

  AudioPlayerInterface() {
    _primaryPlayer = _createPlayer();
    _secondaryPlayer = _createPlayer();

    _bindPlayer(_primaryPlayer, isPrimary: true);
    _bindPlayer(_secondaryPlayer, isPrimary: false);

    _emitPlaybackSnapshot(includePlaylist: true);
  }

  CustomPlayer _createPlayer() {
    final player = CustomPlayer(
      configuration: const mk.PlayerConfiguration(
        title: "Spotube",
        logLevel: kDebugMode ? mk.MPVLogLevel.info : mk.MPVLogLevel.error,
        async: true,
      ),
    );

    player.stream.error.listen((event) {
      AppLogger.reportError(event, StackTrace.current);
    });

    return player;
  }

  CustomPlayer get _activePlayer =>
      _primaryPlayerActive ? _primaryPlayer : _secondaryPlayer;

  CustomPlayer get _inactivePlayer =>
      _primaryPlayerActive ? _secondaryPlayer : _primaryPlayer;

  bool _isActivePlayer(bool isPrimary) => _primaryPlayerActive == isPrimary;

  void _bindPlayer(CustomPlayer player, {required bool isPrimary}) {
    _playerSubscriptions.addAll([
      player.stream.duration.listen((event) {
        if (_isActivePlayer(isPrimary)) {
          _durationStreamController.add(event);
        }
      }),
      player.stream.position.listen((event) {
        if (_isActivePlayer(isPrimary)) {
          _positionStreamController.add(event);
        }
      }),
      player.stream.buffer.listen((event) {
        if (_isActivePlayer(isPrimary)) {
          _bufferedPositionStreamController.add(event);
        }
      }),
      player.stream.playing.listen((event) {
        if (_isActivePlayer(isPrimary)) {
          _isPlaying = event;
          _playingStreamController.add(event);
        }
      }),
      player.shuffleStream.listen((event) {
        if (_isActivePlayer(isPrimary)) {
          _isShuffled = event;
          _shuffledStreamController.add(event);
        }
      }),
      player.stream.playlistMode.listen((event) {
        if (_isActivePlayer(isPrimary)) {
          _loopMode = event;
          _loopModeStreamController.add(event);
        }
      }),
      player.stream.volume.listen((event) {
        if (_isActivePlayer(isPrimary)) {
          _volumeStreamController.add(event / 100);
        }
      }),
      player.stream.buffering.listen((event) {
        if (_isActivePlayer(isPrimary)) {
          _bufferingStreamController.add(event);
        }
      }),
      player.playerStateStream.listen((event) {
        if (_isActivePlayer(isPrimary)) {
          if (_isCrossfading && event == AudioPlaybackState.completed) {
            return;
          }
          _playerStateStreamController.add(event);
        }
      }),
      player.stream.completed.listen((event) {
        if (_isActivePlayer(isPrimary) && event && !_isCrossfading) {
          _completedStreamController.add(null);
        }
      }),
      player.indexChangeStream.listen((index) {
        if (_isActivePlayer(isPrimary) &&
            !_isCrossfading &&
            index != _currentIndex) {
          _syncIndexFromActive(index);
        }
      }),
      player.stream.playlist.listen((event) {
        if (_isActivePlayer(isPrimary)) {
          _syncPlaylistFromActive(event);
        }
      }),
      player.stream.audioDevices.listen((event) {
        if (_isActivePlayer(isPrimary)) {
          _devicesStreamController.add(event);
        }
      }),
      player.stream.audioDevice.listen((event) {
        if (_isActivePlayer(isPrimary)) {
          _selectedDeviceStreamController.add(event);
        }
      }),
      player.stream.error.listen((event) {
        if (_isActivePlayer(isPrimary)) {
          _errorStreamController.add(event);
        }
      }),
    ]);
  }

  void _syncPlaylistFromActive(mk.Playlist playlist) {
    final safeIndex = playlist.medias.isEmpty
        ? -1
        : min(max(_currentIndex, 0), playlist.medias.length - 1);
    _playlist = mk.Playlist(playlist.medias, index: max(safeIndex, 0));
    _playlistStreamController.add(_playlist);
  }

  void _syncIndexFromActive(int index) {
    if (_playlist.medias.isEmpty) {
      _currentIndex = -1;
      return;
    }

    _currentIndex = index.clamp(0, _playlist.medias.length - 1).toInt();
    _emitIndexSnapshot();
    unawaited(_prepareInactivePlayer());
  }

  void _emitIndexSnapshot() {
    _currentIndexStreamController.add(_currentIndex);
    final activeSource = currentSource;
    if (activeSource != null) {
      _activeSourceStreamController.add(activeSource);
    }
    _playlistStreamController.add(
      mk.Playlist(_playlist.medias, index: max(_currentIndex, 0)),
    );
  }

  void _emitPlaybackSnapshot({bool includePlaylist = false}) {
    _durationStreamController.add(duration);
    _positionStreamController.add(position);
    _bufferedPositionStreamController.add(bufferedPosition);
    _playingStreamController.add(isPlaying);
    _shuffledStreamController.add(isShuffled);
    _loopModeStreamController.add(loopMode);
    _volumeStreamController.add(volume);
    _bufferingStreamController.add(isBuffering);
    _devicesStreamController.add(_activePlayer.state.audioDevices);
    _selectedDeviceStreamController.add(_activePlayer.state.audioDevice);

    if (includePlaylist) {
      _playlistStreamController.add(
        mk.Playlist(_playlist.medias, index: max(_currentIndex, 0)),
      );
      final activeSource = currentSource;
      if (activeSource != null) {
        _activeSourceStreamController.add(activeSource);
      }
    }
  }

  int? _nextIndexFrom(int index) {
    if (_playlist.medias.isEmpty || index < 0) return null;
    final next = index + 1;
    if (next < _playlist.medias.length) return next;
    if (_loopMode == PlaylistMode.loop) return 0;
    return null;
  }

  int? _previousIndexFrom(int index) {
    if (_playlist.medias.isEmpty || index < 0) return null;
    final previous = index - 1;
    if (previous >= 0) return previous;
    if (_loopMode == PlaylistMode.loop) return _playlist.medias.length - 1;
    return null;
  }

  Future<void> _openPlayerWithPlaylist(
    CustomPlayer player,
    int index, {
    required bool play,
  }) async {
    if (_playlist.medias.isEmpty) {
      await player.stop();
      return;
    }

    final safeIndex = index.clamp(0, _playlist.medias.length - 1).toInt();
    await player.open(
      mk.Playlist(_playlist.medias, index: safeIndex),
      play: play,
    );
  }

  Future<void> _prepareInactivePlayer() async {
    if (_playlist.medias.isEmpty) {
      await _inactivePlayer.stop();
      return;
    }

    final nextIndex = _nextIndexFrom(_currentIndex);
    if (nextIndex == null) {
      await _inactivePlayer.stop();
      return;
    }

    await _inactivePlayer.setPlaylistMode(_loopMode);
    await _inactivePlayer.setShuffle(_isShuffled);
    await _openPlayerWithPlaylist(_inactivePlayer, nextIndex, play: false);
    await _inactivePlayer.setVolume(0);
  }

  Future<void> _stopCrossfade({
    bool restoreActiveVolume = true,
    bool stopInactivePlayer = true,
  }) async {
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;
    _crossfadeHandoffTimer?.cancel();
    _crossfadeHandoffTimer = null;

    if (stopInactivePlayer && _inactivePlayer.state.playing) {
      await _inactivePlayer.pause();
      await _inactivePlayer.seek(Duration.zero);
      await _inactivePlayer.setVolume(0);
    }

    if (restoreActiveVolume && hasSource) {
      await _activePlayer.setVolume(_targetVolume * 100);
    }

    _isCrossfading = false;
  }

  Future<void> _animateCrossfade(Duration duration) async {
    _crossfadeTimer?.cancel();
    final fadeOutPlayer = _activePlayer;
    final fadeInPlayer = _inactivePlayer;
    if (duration <= const Duration(milliseconds: 50)) {
      await fadeOutPlayer.setVolume(0);
      await fadeInPlayer.setVolume(_targetVolume * 100);
      return;
    }

    const stepMs = 50;
    final steps = max(1, duration.inMilliseconds ~/ stepMs);
    var currentStep = 0;

    _crossfadeTimer =
        Timer.periodic(const Duration(milliseconds: stepMs), (timer) async {
      currentStep++;
      final t = (currentStep / steps).clamp(0.0, 1.0);
      await fadeOutPlayer.setVolume((1 - t) * _targetVolume * 100);
      await fadeInPlayer.setVolume(t * _targetVolume * 100);

      if (currentStep >= steps) {
        timer.cancel();
        _crossfadeTimer = null;
        await fadeOutPlayer.setVolume(0);
        await fadeInPlayer.setVolume(_targetVolume * 100);
      }
    });
  }

  Future<void> _switchActivePlayer(
    int nextIndex, {
    CustomPlayer? expectedOldActive,
    CustomPlayer? expectedNewActive,
  }) async {
    final oldActive = expectedOldActive ?? _activePlayer;
    final newActive = expectedNewActive ?? _inactivePlayer;
    _primaryPlayerActive = !_primaryPlayerActive;
    _currentIndex = nextIndex;
    _isPlaying = newActive.state.playing;
    _emitIndexSnapshot();
    _emitPlaybackSnapshot();

    await oldActive.pause();
    await oldActive.seek(Duration.zero);
    await oldActive.setVolume(0);

    _isCrossfading = false;
    await _prepareInactivePlayer();
  }

  /// Whether the current platform supports the audioplayers plugin
  static const bool _mkSupportedPlatform = true;

  bool get mkSupportedPlatform => _mkSupportedPlatform;

  Duration get duration => _activePlayer.state.duration;

  Playlist get playlist =>
      mk.Playlist(_playlist.medias, index: max(_currentIndex, 0));

  Duration get position => _activePlayer.state.position;

  Duration get bufferedPosition => _activePlayer.state.buffer;

  Future<mk.AudioDevice> get selectedDevice async =>
      _activePlayer.state.audioDevice;

  Future<List<mk.AudioDevice>> get devices async =>
      _activePlayer.state.audioDevices;

  bool get hasSource => _playlist.medias.isNotEmpty;

  bool get isPlaying => _isPlaying;

  bool get isPaused => !isPlaying;

  bool get isStopped => !hasSource;

  Future<bool> get isCompleted async => _activePlayer.state.completed;

  bool get isShuffled => _isShuffled;

  PlaylistMode get loopMode => _loopMode;

  double get volume => _targetVolume;

  bool get isBuffering => _activePlayer.state.buffering;

  int get currentIndex => _currentIndex;

  String? get currentSource {
    if (_currentIndex < 0 || _currentIndex >= _playlist.medias.length) {
      return null;
    }
    return _playlist.medias.elementAt(_currentIndex).uri;
  }

  String? get nextSource {
    final nextIndex = _nextIndexFrom(_currentIndex);
    if (nextIndex == null) return null;
    return _playlist.medias.elementAt(nextIndex).uri;
  }

  String? get previousSource {
    final previousIndex = _previousIndexFrom(_currentIndex);
    if (previousIndex == null) return null;
    return _playlist.medias.elementAt(previousIndex).uri;
  }

  bool get isCrossfading => _isCrossfading;

  Future<bool> startCrossfadeToNext(Duration duration) async {
    final nextIndex = _nextIndexFrom(_currentIndex);
    if (_isCrossfading ||
        !isPlaying ||
        _playlist.medias.isEmpty ||
        nextIndex == null) {
      return false;
    }

    final fadeOutPlayer = _activePlayer;
    final fadeInPlayer = _inactivePlayer;

    await _prepareInactivePlayer();
    await fadeInPlayer.seek(Duration.zero);
    await fadeInPlayer.setVolume(0);
    await fadeInPlayer.play();

    _isCrossfading = true;
    await _animateCrossfade(duration);

    const handoffLead = Duration(milliseconds: 180);
    final handoffDelay = duration > handoffLead
        ? duration - handoffLead
        : Duration.zero;

    _crossfadeHandoffTimer?.cancel();
    _crossfadeHandoffTimer = Timer(handoffDelay, () {
      unawaited(
        _switchActivePlayer(
          nextIndex,
          expectedOldActive: fadeOutPlayer,
          expectedNewActive: fadeInPlayer,
        ),
      );
    });

    return true;
  }

  Future<void> stopCrossfadeAndRestore() async {
    await _stopCrossfade();
    await _prepareInactivePlayer();
  }

  Future<void> disposeControllers() async {
    await _durationStreamController.close();
    await _positionStreamController.close();
    await _bufferedPositionStreamController.close();
    await _completedStreamController.close();
    await _playingStreamController.close();
    await _shuffledStreamController.close();
    await _loopModeStreamController.close();
    await _volumeStreamController.close();
    await _bufferingStreamController.close();
    await _playerStateStreamController.close();
    await _currentIndexStreamController.close();
    await _activeSourceStreamController.close();
    await _devicesStreamController.close();
    await _selectedDeviceStreamController.close();
    await _errorStreamController.close();
    await _playlistStreamController.close();
  }
}
