part of 'audio_player.dart';

final audioPlayer = SpotubeAudioPlayer();

class SpotubeAudioPlayer extends AudioPlayerInterface
    with SpotubeAudioPlayersStreams {
  Future<void> pause() async {
    if (isCrossfading) {
      await _activePlayer.pause();
      await _inactivePlayer.pause();
      _isPlaying = false;
      _playingStreamController.add(false);
      return;
    }

    await _activePlayer.pause();
  }

  Future<void> resume() async {
    if (isCrossfading) {
      await _activePlayer.play();
      await _inactivePlayer.play();
      _isPlaying = true;
      _playingStreamController.add(true);
      return;
    }

    await _activePlayer.play();
  }

  Future<void> stop() async {
    await _stopCrossfade(restoreActiveVolume: false);
    await _primaryPlayer.stop();
    await _secondaryPlayer.stop();
    _playlist = const mk.Playlist([]);
    _currentIndex = -1;
    _isPlaying = false;
    _emitPlaybackSnapshot(includePlaylist: true);
  }

  Future<void> seek(Duration position) async {
    await _activePlayer.seek(position);
  }

  /// Volume is between 0 and 1
  Future<void> setVolume(double volume) async {
    assert(volume >= 0 && volume <= 1);
    final previousTargetVolume = _targetVolume <= 0 ? 1.0 : _targetVolume;
    _targetVolume = volume;

    if (isCrossfading) {
      final activeRatio = (_activePlayer.state.volume / 100) / previousTargetVolume;
      final inactiveRatio =
          (_inactivePlayer.state.volume / 100) / previousTargetVolume;
      await _activePlayer.setVolume(activeRatio.clamp(0.0, 1.0) * volume * 100);
      await _inactivePlayer.setVolume(
        inactiveRatio.clamp(0.0, 1.0) * volume * 100,
      );
      return;
    }

    await _activePlayer.setVolume(volume * 100);
    if (!_inactivePlayer.state.playing) {
      await _inactivePlayer.setVolume(0);
    }
  }

  Future<void> setSpeed(double speed) async {
    await _activePlayer.setRate(speed);
    await _inactivePlayer.setRate(speed);
  }

  Future<void> setAudioDevice(mk.AudioDevice device) async {
    await _activePlayer.setAudioDevice(device);
    await _inactivePlayer.setAudioDevice(device);
  }

  Future<void> dispose() async {
    await _stopCrossfade(restoreActiveVolume: false);
    for (final subscription in _playerSubscriptions) {
      await subscription.cancel();
    }
    await disposeControllers();
    await _primaryPlayer.dispose();
    await _secondaryPlayer.dispose();
  }

  Future<void> openPlaylist(
    List<mk.Media> tracks, {
    bool autoPlay = true,
    int initialIndex = 0,
  }) async {
    assert(tracks.isNotEmpty);
    assert(initialIndex <= tracks.length - 1);

    await _stopCrossfade(restoreActiveVolume: false);

    final safeInitialIndex = initialIndex.clamp(0, tracks.length - 1).toInt();
    _playlist = mk.Playlist(tracks, index: safeInitialIndex);
    _currentIndex = safeInitialIndex;
    _primaryPlayerActive = true;

    await _primaryPlayer.setPlaylistMode(_loopMode);
    await _secondaryPlayer.setPlaylistMode(_loopMode);
    await _primaryPlayer.setShuffle(_isShuffled);
    await _secondaryPlayer.setShuffle(_isShuffled);

    await _openPlayerWithPlaylist(
      _primaryPlayer,
      safeInitialIndex,
      play: autoPlay,
    );
    await _primaryPlayer.setVolume(_targetVolume * 100);
    await _prepareInactivePlayer();
    _isPlaying = autoPlay;
    _emitPlaybackSnapshot(includePlaylist: true);
  }

  List<String> get sources {
    return _playlist.medias.map((e) => e.uri).toList();
  }

  Future<void> skipToNext() async {
    await _stopCrossfade();
    await _activePlayer.next();
  }

  Future<void> skipToPrevious() async {
    await _stopCrossfade();
    await _activePlayer.previous();
  }

  Future<void> jumpTo(int index) async {
    await _stopCrossfade();
    await _activePlayer.jump(index);
  }

  Future<void> addTrack(mk.Media media) async {
    await _primaryPlayer.add(media);
    await _secondaryPlayer.add(media);
    _syncPlaylistFromActive(_activePlayer.state.playlist);
    await _prepareInactivePlayer();
  }

  Future<void> addTrackAt(mk.Media media, int index) async {
    await _primaryPlayer.insert(index, media);
    await _secondaryPlayer.insert(index, media);
    _syncPlaylistFromActive(_activePlayer.state.playlist);
    await _prepareInactivePlayer();
  }

  Future<void> removeTrack(int index) async {
    await _stopCrossfade();
    await _primaryPlayer.remove(index);
    await _secondaryPlayer.remove(index);

    if (_primaryPlayer.state.playlist.medias.isEmpty) {
      _playlist = const mk.Playlist([]);
      _currentIndex = -1;
      _emitPlaybackSnapshot(includePlaylist: true);
      return;
    }

    _currentIndex =
        min(_currentIndex, _primaryPlayer.state.playlist.medias.length - 1);
    _syncPlaylistFromActive(_activePlayer.state.playlist);
    _emitIndexSnapshot();
    await _prepareInactivePlayer();
  }

  Future<void> moveTrack(int from, int to) async {
    await _primaryPlayer.move(from, to);
    await _secondaryPlayer.move(from, to);
    _syncPlaylistFromActive(_activePlayer.state.playlist);
    _emitIndexSnapshot();
    await _prepareInactivePlayer();
  }

  Future<void> clearPlaylist() async {
    await stop();
  }

  Future<void> setShuffle(bool shuffle) async {
    _isShuffled = shuffle;
    await _primaryPlayer.setShuffle(shuffle);
    await _secondaryPlayer.setShuffle(shuffle);
    _shuffledStreamController.add(shuffle);
    _syncPlaylistFromActive(_activePlayer.state.playlist);
    await _prepareInactivePlayer();
  }

  Future<void> setLoopMode(PlaylistMode loop) async {
    _loopMode = loop;
    await _primaryPlayer.setPlaylistMode(loop);
    await _secondaryPlayer.setPlaylistMode(loop);
    _loopModeStreamController.add(loop);
    await _prepareInactivePlayer();
  }

  Future<void> setAudioNormalization(bool normalize) async {
    await _primaryPlayer.setAudioNormalization(normalize);
    await _secondaryPlayer.setAudioNormalization(normalize);
  }

  Future<void> setDemuxerBufferSize(int sizeInBytes) async {
    await _primaryPlayer.setDemuxerBufferSize(sizeInBytes);
    await _secondaryPlayer.setDemuxerBufferSize(sizeInBytes);
  }
}
