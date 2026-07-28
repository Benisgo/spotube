import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:media_kit/media_kit.dart' as mk;
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/audio_player/custom_player.dart';
import 'package:spotube/services/audio_player/playback_state.dart';
import 'package:spotube/services/youtube_engine/android_yt_dlp_engine.dart';
import 'package:spotube/utils/platform.dart';

part 'audio_players_streams_mixin.dart';
part 'audio_player_impl.dart';

class SpotubeMedia extends mk.Media {
  static int serverPort = 0;
  static const _directUrlExtrasKey = '_spotubeDirectUrl';
  static const _httpHeadersExtrasKey = '_spotubeHttpHeaders';

  static String get _host =>
      kIsWindows ? "localhost" : InternetAddress.loopbackIPv4.address;

  static Map<String, String>? headersForDirectUrl(String? directUrl) {
    if (directUrl == null || directUrl.isEmpty) return null;

    try {
      final ytDlpHeaders = AndroidYtDlpEngine.headersForUrl(directUrl);
      if (ytDlpHeaders != null && ytDlpHeaders.isNotEmpty) {
        return ytDlpHeaders;
      }
    } catch (_) {}

    final uri = Uri.tryParse(directUrl);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    if (!host.contains('googlevideo.com') &&
        !host.contains('youtube.com') &&
        !host.contains('youtu.be')) {
      return null;
    }

    return const {
      "user-agent":
          "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.6367.83 Mobile Safari/537.36",
      "accept": "*/*",
      "accept-language": "en-US,en;q=0.5",
      "origin": "https://www.youtube.com",
      "referer": "https://www.youtube.com/",
    };
  }

  final SpotubeTrackObject track;
  SpotubeMedia(
    this.track, {
    String? directUrl,
    Map<String, String>? httpHeaders,
  })  : assert(
          track is SpotubeLocalTrackObject || track is SpotubeFullTrackObject,
          "Track must be a either a local track or a full track object with ISRC",
        ),
        super(
          track is SpotubeLocalTrackObject
              ? track.path
              : directUrl ?? "http://$_host:$serverPort/stream/${track.id}",
          extras: {
            ...track.toJson(),
            if (directUrl != null && directUrl.isNotEmpty)
              _directUrlExtrasKey: directUrl,
            if (httpHeaders != null && httpHeaders.isNotEmpty)
              _httpHeadersExtrasKey: httpHeaders,
          },
          httpHeaders: httpHeaders,
        );

  factory SpotubeMedia.media(Media media) {
    assert(media.extras != null, "[Media] must have extra metadata set");
    final extras = media.extras!;
    final rawHeaders = extras[_httpHeadersExtrasKey];
    return SpotubeMedia(
      SpotubeTrackObject.fromJson(extras),
      directUrl: extras[_directUrlExtrasKey] as String?,
      httpHeaders: rawHeaders is Map
          ? rawHeaders.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
          : null,
    );
  }
}

abstract class AudioPlayerInterface {
  static const _playerCommandTimeout = Duration(seconds: 4);
  static const _backgroundPlayerCommandTimeout = Duration(seconds: 2);
  late final CustomPlayer _primaryPlayer;
  CustomPlayer? _secondaryPlayer;

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
  final List<StreamSubscription> _secondarySubscriptions = [];

  mk.Playlist _playlist = const mk.Playlist([]);
  int _currentIndex = -1;
  bool _isPlaying = false;
  bool _isShuffled = false;
  PlaylistMode _loopMode = PlaylistMode.none;
  double _targetVolume = 1.0;
  bool _primaryPlayerActive = true;
  bool _isCrossfading = false;
  bool _crossfadePreloadEnabled = false;
  bool _resumeAfterCompletedAdvancePending = false;
  bool _suppressCompletedAdvanceRecovery = false;
  bool _skipInProgress = false;
  bool _crossfadeHandoffPending = false;
  bool _isStoppingCrossfade = false;
  Timer? _completedAdvanceTimer;
  Timer? _crossfadeTimer;
  Timer? _crossfadeHandoffTimer;
  String? _lastEmittedPlaylistSignature;
  DateTime? _lastPositionForwardedAt;

  String _playlistSignature(mk.Playlist playlist) =>
      '${playlist.medias.length}:${playlist.index}:${playlist.medias.map((m) => m.uri).join("|")}';

  void _emitPlaylistSnapshot(mk.Playlist playlist) {
    final signature = _playlistSignature(playlist);
    if (_lastEmittedPlaylistSignature == signature) return;
    _lastEmittedPlaylistSignature = signature;
    _playlistStreamController.add(playlist);
  }

  Future<void> _executeSkip(
    Future<void> Function() skipFn,
  ) async {
    if (_skipInProgress) return;
    _skipInProgress = true;
    setSuppressCompletedAdvanceRecovery(true);
    try {
      await skipFn();
    } finally {
      _skipInProgress = false;
      setSuppressCompletedAdvanceRecovery(false);
    }
  }

  void _trace(String message) {}

  void _critical(String message) {}

  bool get _mirrorsSecondaryPlayer =>
      _crossfadePreloadEnabled || _isCrossfading;

  Future<void> _mirrorSecondary(
    Future<void> Function(CustomPlayer player) action,
  ) async {
    if (!_mirrorsSecondaryPlayer) return;
    await _ensureSecondaryPlayer();
    await action(_secondaryPlayer!);
  }

  Future<void> _ensureSecondaryPlayer() async {
    if (_secondaryPlayer != null) return;
    _secondaryPlayer = _createPlayer();
    _bindPlayer(
      _secondaryPlayer!,
      isPrimary: false,
      into: _secondarySubscriptions,
    );
  }

  Future<void> _disposeSecondaryPlayer() async {
    if (_secondaryPlayer == null) return;
    try {
      await _secondaryPlayer!.stop();
    } catch (_) {}
    for (final subscription in _secondarySubscriptions) {
      await subscription.cancel();
    }
    _secondarySubscriptions.clear();
    await _secondaryPlayer!.dispose();
    _secondaryPlayer = null;
  }

  AudioPlayerInterface() {
    _primaryPlayer = _createPlayer();
    _bindPlayer(_primaryPlayer, isPrimary: true, into: _playerSubscriptions);
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

    return player;
  }

  CustomPlayer get _activePlayer {
    final secondary = _secondaryPlayer;
    if (secondary == null) return _primaryPlayer;
    return _primaryPlayerActive ? _primaryPlayer : secondary;
  }

  CustomPlayer get _inactivePlayer {
    final secondary = _secondaryPlayer;
    if (secondary == null) return _primaryPlayer;
    return _primaryPlayerActive ? secondary : _primaryPlayer;
  }

  bool _isActivePlayer(bool isPrimary) => _primaryPlayerActive == isPrimary;

  Future<T> _withPlayerTimeout<T>(
    Future<T> future,
    String label, {
    Duration timeout = _playerCommandTimeout,
  }) async {
    try {
      return await future.timeout(timeout);
    } on TimeoutException {
      throw TimeoutException('Audio player command timed out: $label', timeout);
    }
  }

  Future<void> _bestEffortPlayerCommand(
    Future<void> future,
    String label, {
    Duration timeout = _backgroundPlayerCommandTimeout,
  }) async {
    try {
      await future.timeout(timeout);
    } catch (error, stackTrace) {
      await AppLogger.reportError(
        error,
        stackTrace,
        'Best-effort audio player command failed: $label',
      );
    }
  }

  Future<void> _forceActivateIndex(
    int index, {
    bool? play,
  }) async {
    if (_playlist.medias.isEmpty) return;
    final safeIndex = index.clamp(0, _playlist.medias.length - 1).toInt();
    await _withPlayerTimeout(
      _openPlayerWithPlaylist(
        _activePlayer,
        safeIndex,
        play: play ?? _isPlaying,
      ),
      'forceActivateIndex($safeIndex)',
    );
    await _bestEffortPlayerCommand(
      _activePlayer.setVolume(_targetVolume * 100),
      'forceActivateIndex.setVolume($safeIndex)',
    );
    await _bestEffortPlayerCommand(
      _activePlayer.reapplyNormalizationIfNeeded(),
      'forceActivateIndex.reapplyNormalization',
    );
    _syncIndexFromActive(safeIndex);
    _emitPlaybackSnapshot(includePlaylist: true);
  }

  void _bindPlayer(
    CustomPlayer player, {
    required bool isPrimary,
    required List<StreamSubscription> into,
  }) {
    into.addAll([
      player.stream.duration.listen((event) {
        if (_isActivePlayer(isPrimary)) {
          _durationStreamController.add(event);
        }
      }),
      player.stream.position.listen((event) {
        if (!_isActivePlayer(isPrimary)) return;
        final now = DateTime.now();
        if (_lastPositionForwardedAt != null &&
            now.difference(_lastPositionForwardedAt!) <
                const Duration(milliseconds: 200)) {
          return;
        }
        _lastPositionForwardedAt = now;
        _positionStreamController.add(event);
      }),
      player.stream.buffer.listen((event) {
        if (_isActivePlayer(isPrimary)) {
          _bufferedPositionStreamController.add(event);
        }
      }),
      player.stream.playing.listen((event) {
        if (_isActivePlayer(isPrimary)) {
          _isPlaying = event;
          if (event) {
            _resumeAfterCompletedAdvancePending = false;
            _completedAdvanceTimer?.cancel();
            _completedAdvanceTimer = null;
            _suppressCompletedAdvanceRecovery = false;
          }
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
          _critical("buffering=$event isPrimary=$isPrimary");
          _bufferingStreamController.add(event);
        }
      }),
      player.playerStateStream.listen((event) {
        if (_isActivePlayer(isPrimary)) {
          if (_isCrossfading && event == AudioPlaybackState.completed) {
            return;
          }
          _critical("playerState=$event isPrimary=$isPrimary");
          _playerStateStreamController.add(event);
        }
      }),
      player.stream.completed.listen((event) {
        if (_isActivePlayer(isPrimary) && event && !_isCrossfading) {
          final alreadyPending = _resumeAfterCompletedAdvancePending;
          _resumeAfterCompletedAdvancePending =
              !_suppressCompletedAdvanceRecovery &&
                  _nextIndexFrom(_currentIndex) != null;
          if (!_suppressCompletedAdvanceRecovery && !alreadyPending) {
            _scheduleCompletedAdvanceRecovery();
          } else if (alreadyPending) {
            // A recovery is already in progress. Suppress any further
            // recovery scheduling until playback resumes, to prevent
            // async completed events from jump() during recovery from
            // creating an infinite loop.
            _suppressCompletedAdvanceRecovery = true;
          }
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
          _critical("playerError=$event isPrimary=$isPrimary");
          _errorStreamController.add(event);
        }
      }),
    ]);
  }

  void _syncPlaylistFromActive(mk.Playlist playlist) {
    _trace(
      "syncPlaylistFromActive medias=${playlist.medias.length} playlistIndex=${playlist.index}",
    );
    final safeIndex = playlist.medias.isEmpty
        ? -1
        : min(max(_currentIndex, 0), playlist.medias.length - 1);
    _playlist = mk.Playlist(playlist.medias, index: max(safeIndex, 0));
    _emitPlaylistSnapshot(_playlist);
  }

  void _syncIndexFromActive(int index) {
    _trace("syncIndexFromActive incoming=$index");
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
    _emitPlaylistSnapshot(
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
      _emitPlaylistSnapshot(
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
    final medias = _playlist.medias;
    if (medias.isEmpty) {
      await player.stop();
      return;
    }

    final safeIndex = index.clamp(0, medias.length - 1).toInt();
    _critical(
      "openPlayerWithPlaylist index=$safeIndex play=$play uri=${medias[safeIndex].uri}",
    );
    await _withPlayerTimeout(
      player.open(
        mk.Playlist(medias, index: safeIndex),
        play: play,
      ),
      'player.open(index=$safeIndex, play=$play)',
    );
    _critical(
      "openPlayerWithPlaylist complete index=$safeIndex play=$play uri=${medias[safeIndex].uri}",
    );
  }

  Future<void> _prepareInactivePlayer() async {
    _trace("prepareInactivePlayer preload=$_crossfadePreloadEnabled");
    _critical("prepareInactivePlayer preload=$_crossfadePreloadEnabled");
    if (!_crossfadePreloadEnabled) {
      if (_secondaryPlayer != null) {
        await _bestEffortPlayerCommand(
          _inactivePlayer.stop(),
          'inactive.stop.preload_disabled',
        );
      }
      return;
    }

    if (!_isPlaying) {
      return;
    }

    if (_playlist.medias.isEmpty) {
      await _bestEffortPlayerCommand(
        _inactivePlayer.stop(),
        'inactive.stop.empty_playlist',
      );
      return;
    }

    await _ensureSecondaryPlayer();

    final nextIndex = _nextIndexFrom(_currentIndex);
    if (nextIndex == null) {
      await _bestEffortPlayerCommand(
        _inactivePlayer.stop(),
        'inactive.stop.no_next_index',
      );
      return;
    }

    await _bestEffortPlayerCommand(
      _inactivePlayer.setPlaylistMode(_loopMode),
      'inactive.setPlaylistMode',
    );
    await _bestEffortPlayerCommand(
      _inactivePlayer.setShuffle(_isShuffled),
      'inactive.setShuffle',
    );
    await _bestEffortPlayerCommand(
      _openPlayerWithPlaylist(_inactivePlayer, nextIndex, play: false),
      'inactive.open(next=$nextIndex)',
      timeout: _playerCommandTimeout,
    );
    await _bestEffortPlayerCommand(
      _inactivePlayer.setVolume(0),
      'inactive.setVolume(0)',
    );
  }

  Future<void> _stopCrossfade({
    bool restoreActiveVolume = true,
    bool stopInactivePlayer = true,
  }) async {
    if (_isStoppingCrossfade) return;
    _isStoppingCrossfade = true;
    _crossfadeHandoffPending = false;
    try {
      _crossfadeTimer?.cancel();
      _crossfadeTimer = null;
      _crossfadeHandoffTimer?.cancel();
      _crossfadeHandoffTimer = null;
      _completedAdvanceTimer?.cancel();
      _completedAdvanceTimer = null;

      if (_secondaryPlayer != null &&
          stopInactivePlayer &&
          _inactivePlayer.state.playing) {
        await _bestEffortPlayerCommand(
          _inactivePlayer.pause(),
          'inactive.pause.stopCrossfade',
        );
        await _bestEffortPlayerCommand(
          _inactivePlayer.seek(Duration.zero),
          'inactive.seek.stopCrossfade',
        );
        await _bestEffortPlayerCommand(
          _inactivePlayer.setVolume(0),
          'inactive.setVolume.stopCrossfade',
        );
      }

      if (restoreActiveVolume && hasSource) {
        await _bestEffortPlayerCommand(
          _activePlayer.setVolume(_targetVolume * 100),
          'active.setVolume.restore',
        );
      }

      _isCrossfading = false;
    } finally {
      _isStoppingCrossfade = false;
    }
  }

  Future<void> _resumeAfterCompletedAdvance() async {
    if (_playlist.medias.isEmpty || _isCrossfading) return;
    if (_activePlayer.state.playing) return;

    try {
      await _bestEffortPlayerCommand(
        _activePlayer.seek(Duration.zero),
        'active.seek.resumeAfterCompletedAdvance',
      );
    } catch (_) {}
    await _withPlayerTimeout(
      _activePlayer.play(),
      'active.play.resumeAfterCompletedAdvance',
    );
  }

  void _scheduleCompletedAdvanceRecovery() {
    _completedAdvanceTimer?.cancel();
    _completedAdvanceTimer = Timer(const Duration(milliseconds: 180), () {
      unawaited(_recoverCompletedAdvance());
    });
  }

  Future<void> _recoverCompletedAdvance() async {
    if (_playlist.medias.isEmpty || _isCrossfading) return;
    if (!_resumeAfterCompletedAdvancePending) return;
    if (_activePlayer.state.playing) {
      _resumeAfterCompletedAdvancePending = false;
      return;
    }

    // Only use seek(0) + play() — never jump(). The jump() method causes
    // MPV to reload media, which fires async completed events that can
    // re-trigger recovery scheduling even with suppress flags, AND can
    // block the Windows message pump on expired streaming URLs (freezing
    // the UI). seek(0) + play() is safe: if MPV already advanced to the
    // next track but is stalled on buffering, play() resumes it. If the
    // next track's URL is truly expired, MPV handles the failure cleanly
    // without blocking.
    await _resumeAfterCompletedAdvance();

    // Give MPV a moment to start playback before giving up entirely.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    if (!_activePlayer.state.playing) {
      await _resumeAfterCompletedAdvance();
    }

    _resumeAfterCompletedAdvancePending = false;
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

  bool get canSkipToPrevious => _previousIndexFrom(_currentIndex) != null;

  bool get isCrossfading => _isCrossfading;

  void setSuppressCompletedAdvanceRecovery(bool suppress) {
    _suppressCompletedAdvanceRecovery = suppress;
    if (suppress) {
      _resumeAfterCompletedAdvancePending = false;
      _completedAdvanceTimer?.cancel();
      _completedAdvanceTimer = null;
    }
  }

  Future<bool> startCrossfadeToNext(Duration duration) async {
    await _ensureSecondaryPlayer();
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
    final handoffDelay =
        duration > handoffLead ? duration - handoffLead : Duration.zero;

    _crossfadeHandoffPending = true;
    _crossfadeHandoffTimer?.cancel();
    _crossfadeHandoffTimer = Timer(handoffDelay, () {
      if (!_crossfadeHandoffPending) return;
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

  Future<void> setCrossfadePreloadEnabled(bool enabled) async {
    _crossfadePreloadEnabled = enabled;

    if (!enabled) {
      await _disposeSecondaryPlayer();
      return;
    }

    await _ensureSecondaryPlayer();
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
