part of 'audio_player.dart';

final audioPlayer = SpotubeAudioPlayer();

bool _appClosing = false;

/// Best-effort, idempotent audio shutdown shared by every app-exit path.
/// Aborts the active stream so libmpv doesn't block process teardown for 3-5s.
/// The `_appClosing` guard (plus the `_isDisposed` guard inside dispose) makes
/// repeated calls safe across the window-X, tray, notification, keyboard
/// shortcut, and sleep-timer close paths.
Future<void> disposeAudioPlayerForClose() async {
  if (_appClosing) return;
  _appClosing = true;
  try {
    await audioPlayer.dispose().timeout(const Duration(seconds: 2));
  } catch (_) {
    // Never let audio teardown block the close.
  }
}

class SpotubeAudioPlayer extends AudioPlayerInterface
    with SpotubeAudioPlayersStreams {
  Future<void> pause() async {
    _trace("pause");
    if (isCrossfading) {
      await _bestEffortPlayerCommand(
        _activePlayer.pause(),
        'active.pause.crossfading',
      );
      await _bestEffortPlayerCommand(
        _inactivePlayer.pause(),
        'inactive.pause.crossfading',
      );
      _isPlaying = false;
      _playingStreamController.add(false);
      return;
    }

    await _withPlayerTimeout(_activePlayer.pause(), 'active.pause');
  }

  Future<void> resume() async {
    _trace("resume");
    if (isCrossfading) {
      await _withPlayerTimeout(_activePlayer.play(), 'active.play.crossfading');
      await _bestEffortPlayerCommand(
        _inactivePlayer.play(),
        'inactive.play.crossfading',
      );
      _isPlaying = true;
      _playingStreamController.add(true);
      return;
    }

    await _withPlayerTimeout(_activePlayer.play(), 'active.play');
  }

  Future<void> stop() async {
    _trace("stop");
    if (_isDisposed) return;
    await _stopCrossfade(restoreActiveVolume: false);
    await _primaryPlayer.stop();
    await _mirrorSecondary((player) => player.stop());
    _playlist = const mk.Playlist([]);
    _currentIndex = -1;
    _isPlaying = false;
    _emitPlaybackSnapshot(includePlaylist: true);
  }

  Future<void> seek(Duration position) async {
    if (_isDisposed) return;
    await _activePlayer.seek(position);
  }

  /// Volume is between 0 and 1
  Future<void> setVolume(double volume) async {
    assert(volume >= 0 && volume <= 1);
    _volumeInitialized = true;
    final previousTargetVolume = _targetVolume <= 0 ? 1.0 : _targetVolume;
    _targetVolume = volume;
    try {
      await KVStoreService.setVolume(volume);
    } catch (_) {}

    if (isCrossfading) {
      final activeRatio =
          (_activePlayer.state.volume / 100) / previousTargetVolume;
      final inactiveRatio =
          (_inactivePlayer.state.volume / 100) / previousTargetVolume;
      await _activePlayer.setVolume(activeRatio.clamp(0.0, 1.0) * volume * 100);
      await _inactivePlayer.setVolume(
        inactiveRatio.clamp(0.0, 1.0) * volume * 100,
      );
      return;
    }

    await _activePlayer.setVolume(volume * 100);
  }

  Future<void> setSpeed(double speed) async {
    await _activePlayer.setRate(speed);
    await _mirrorSecondary((player) => player.setRate(speed));
  }

  Future<void> setAudioDevice(mk.AudioDevice device) async {
    await _activePlayer.setAudioDevice(device);
    await _mirrorSecondary((player) => player.setAudioDevice(device));
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await _stopCrossfade(restoreActiveVolume: false);
    for (final subscription in _playerSubscriptions) {
      await subscription.cancel();
    }
    await disposeControllers();
    await _primaryPlayer.dispose();
    await _disposeSecondaryPlayer();
  }

  Future<void> openPlaylist(
    List<mk.Media> tracks, {
    bool autoPlay = true,
    int initialIndex = 0,
  }) async {
    if (_isDisposed) return;
    await _executeSkip(() async {
      assert(tracks.isNotEmpty);
      assert(initialIndex <= tracks.length - 1);

      _trace(
        "openPlaylist tracks=${tracks.length} initialIndex=$initialIndex autoPlay=$autoPlay",
      );
      _critical(
        "openPlaylist tracks=${tracks.length} initialIndex=$initialIndex autoPlay=$autoPlay",
      );
      await _stopCrossfade(restoreActiveVolume: false);

      final safeInitialIndex = initialIndex.clamp(0, tracks.length - 1).toInt();
      _playlist = mk.Playlist(tracks, index: safeInitialIndex);
      _currentIndex = safeInitialIndex;
      _primaryPlayerActive = true;

      await _primaryPlayer.setPlaylistMode(_loopMode);
      await _primaryPlayer.setShuffle(_isShuffled);
      await _mirrorSecondary((player) async {
        await player.setPlaylistMode(_loopMode);
        await player.setShuffle(_isShuffled);
      });

      await _openPlayerWithPlaylist(
        _primaryPlayer,
        safeInitialIndex,
        play: autoPlay,
      );
      _initVolumeFromStoreIfNeeded();
      await _primaryPlayer.setVolume(_targetVolume * 100);
      await _primaryPlayer.reapplyNormalizationIfNeeded();
      if (kIsWindows && autoPlay) {
        await _primaryPlayer.primeWindowsPipeline();
      }
      await _prepareInactivePlayer();
      _isPlaying = autoPlay;
      _emitPlaybackSnapshot(includePlaylist: true);
    });
  }

  List<String> get sources {
    return _playlist.medias.map((e) => e.uri).toList();
  }

  Future<void> skipToNext() async {
    if (_isDisposed) return;
    await _executeSkip(() async {
      _trace("skipToNext");
      final nextIndex = _nextIndexFrom(_currentIndex);
      await _stopCrossfade();
      try {
        await _withPlayerTimeout(_activePlayer.next(), 'active.next');
        await _activePlayer.reapplyNormalizationIfNeeded();
      } catch (_) {
        if (nextIndex != null) {
          await _forceActivateIndex(nextIndex);
          return;
        }
        rethrow;
      }
    });
  }

  Future<void> skipToPrevious() async {
    if (_isDisposed) return;
    await _executeSkip(() async {
      _trace("skipToPrevious");
      final previousIndex = _previousIndexFrom(_currentIndex);
      await _stopCrossfade();
      try {
        await _withPlayerTimeout(_activePlayer.previous(), 'active.previous');
        await _activePlayer.reapplyNormalizationIfNeeded();
      } catch (_) {
        if (previousIndex != null) {
          await _forceActivateIndex(previousIndex);
          return;
        }
        rethrow;
      }
    });
  }

  Future<void> jumpTo(int index) async {
    if (_isDisposed) return;
    await _executeSkip(() async {
      _trace("jumpTo index=$index");
      await _stopCrossfade();
      try {
        await _withPlayerTimeout(
            _activePlayer.jump(index), 'active.jump($index)');
        await _activePlayer.reapplyNormalizationIfNeeded();
      } catch (_) {
        await _forceActivateIndex(index);
      }
    });
  }

  Future<void> addTrack(mk.Media media) async {
    _trace("addTrack uri=${media.uri}");
    if (_isDisposed) {
      return;
    }
    try {
      await _primaryPlayer.add(media);
    } catch (_) {
      if (_isDisposed) {
        return; // player disposed mid-command (app closing) — swallow
      }
      rethrow;
    }
    if (_isBatching) {
      // Sync from the primary — NOT the active player. If a crossfade completes
      // mid-batch the secondary becomes active and its bound listener drops these
      // events (it is gated on _isActivePlayer(isPrimary)), so _playlist would
      // silently stop growing. O(1): Playlist stores medias by ref and the sync
      // skips emission while batching.
      _syncPlaylistFromActive(_primaryPlayer.state.playlist);
      return;
    }
    await _mirrorSecondary((player) => player.add(media));
    _syncPlaylistFromActive(_activePlayer.state.playlist);
    await _prepareInactivePlayer();
  }

  Future<void> addTrackAt(mk.Media media, int index) async {
    _trace("addTrackAt uri=${media.uri} index=$index");
    if (_isDisposed) {
      return;
    }
    if (_playlist.medias.isEmpty || _currentIndex < 0) {
      await addTrack(media);
      return;
    }

    try {
      await _primaryPlayer.insert(index, media);
    } catch (_) {
      if (_isDisposed) {
        return;
      }
      rethrow;
    }
    if (_isBatching) {
      _syncPlaylistFromActive(_primaryPlayer.state.playlist);
      return;
    }
    await _mirrorSecondary((player) => player.insert(index, media));
    _syncPlaylistFromActive(_activePlayer.state.playlist);
    await _prepareInactivePlayer();
  }

  Future<void> removeTrack(int index) async {
    await _executeSkip(() async {
      _trace("removeTrack index=$index");
      await _stopCrossfade();
      await _primaryPlayer.remove(index);
      await _mirrorSecondary((player) => player.remove(index));

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
    });
  }

  Future<void> moveTrack(int from, int to) async {
    _trace("moveTrack from=$from to=$to");
    await _primaryPlayer.move(from, to);
    await _mirrorSecondary((player) => player.move(from, to));
    _syncPlaylistFromActive(_activePlayer.state.playlist);
    _emitIndexSnapshot();
    await _prepareInactivePlayer();
  }

  Future<void> clearPlaylist() async {
    await stop();
  }

  Future<void> setShuffle(bool shuffle) async {
    _trace("setShuffle shuffle=$shuffle");
    _isShuffled = shuffle;
    await _primaryPlayer.setShuffle(shuffle);
    await _mirrorSecondary((player) => player.setShuffle(shuffle));
    _shuffledStreamController.add(shuffle);
    _syncPlaylistFromActive(_activePlayer.state.playlist);
    await _prepareInactivePlayer();
  }

  Future<void> setLoopMode(PlaylistMode loop) async {
    _trace("setLoopMode loop=$loop");
    _loopMode = loop;
    await _primaryPlayer.setPlaylistMode(loop);
    await _mirrorSecondary((player) => player.setPlaylistMode(loop));
    _loopModeStreamController.add(loop);
    await _prepareInactivePlayer();
  }

  Future<void> setAudioNormalization(bool normalize) async {
    await _primaryPlayer.setAudioNormalization(normalize);
    await _mirrorSecondary((player) => player.setAudioNormalization(normalize));
  }

  Future<void> setDemuxerBufferSize(int sizeInBytes) async {
    await _primaryPlayer.setDemuxerBufferSize(sizeInBytes);
    await _mirrorSecondary(
        (player) => player.setDemuxerBufferSize(sizeInBytes));
  }
}
