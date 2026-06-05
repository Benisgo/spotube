part of 'audio_player.dart';

mixin SpotubeAudioPlayersStreams on AudioPlayerInterface {
  Stream<Duration> get durationStream => _durationStreamController.stream;

  Stream<Duration> get positionStream => _positionStreamController.stream;

  Stream<Duration> get bufferedPositionStream =>
      _bufferedPositionStreamController.stream;

  Stream<void> get completedStream => _completedStreamController.stream;

  /// Stream that emits when the player is almost (%) complete
  Stream<int> percentCompletedStream(double percent) {
    return positionStream
        .asyncMap(
          (position) async => duration == Duration.zero
              ? 0
              : (position.inSeconds / duration.inSeconds * 100).toInt(),
        )
        .where((event) => event >= percent);
  }

  Stream<bool> get playingStream => _playingStreamController.stream;

  Stream<bool> get shuffledStream => _shuffledStreamController.stream;

  Stream<PlaylistMode> get loopModeStream => _loopModeStreamController.stream;

  Stream<double> get volumeStream => _volumeStreamController.stream;

  Stream<bool> get bufferingStream => _bufferingStreamController.stream;

  Stream<AudioPlaybackState> get playerStateStream =>
      _playerStateStreamController.stream;

  Stream<int> get currentIndexChangedStream =>
      _currentIndexStreamController.stream;

  Stream<String> get activeSourceChangedStream =>
      _activeSourceStreamController.stream;

  Stream<List<mk.AudioDevice>> get devicesStream =>
      _devicesStreamController.stream;

  Stream<mk.AudioDevice> get selectedDeviceStream =>
      _selectedDeviceStreamController.stream;

  Stream<String> get errorStream => _errorStreamController.stream;

  Stream<mk.Playlist> get playlistStream => _playlistStreamController.stream;
}
