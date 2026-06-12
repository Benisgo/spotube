import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotube/collections/routes.dart';
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/models/multi_session/multi_session.dart';
import 'package:spotube/modules/player/player_controls.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/audio_player/querying_track_info.dart';
import 'package:spotube/provider/multi_session/multi_session.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/utils/platform.dart';

class PlayPauseIntent extends Intent {
  final WidgetRef ref;
  const PlayPauseIntent(this.ref);
}

class PlayPauseAction extends Action<PlayPauseIntent> {
  @override
  invoke(intent) async {
    if (PlayerControls.focusNode.canRequestFocus) {
      PlayerControls.focusNode.requestFocus();
    }

    final multiSession = intent.ref.read(multiSessionProvider);
    if (multiSession.connected &&
        !multiSession.can(MultiSessionPermission.controlPlayback)) {
      await intent.ref
          .read(multiSessionProvider.notifier)
          .toggleLocalPlaybackPaused();
      return null;
    }

    if (!audioPlayer.isPlaying) {
      await audioPlayer.resume();
    } else {
      await audioPlayer.pause();
    }
    return null;
  }
}

class PlayIntent extends Intent {
  const PlayIntent();
}

class PlayAction extends Action<PlayIntent> {
  @override
  invoke(intent) async {
    await audioPlayer.resume();
    return null;
  }
}

class PauseIntent extends Intent {
  const PauseIntent();
}

class PauseAction extends Action<PauseIntent> {
  @override
  invoke(intent) async {
    await audioPlayer.pause();
    return null;
  }
}

class NextTrackIntent extends Intent {
  const NextTrackIntent();
}

class NextTrackAction extends Action<NextTrackIntent> {
  @override
  invoke(intent) async {
    await audioPlayer.skipToNext();
    return null;
  }
}

class PreviousTrackIntent extends Intent {
  const PreviousTrackIntent();
}

class PreviousTrackAction extends Action<PreviousTrackIntent> {
  @override
  invoke(intent) async {
    final position = audioPlayer.position;
    if (position.inSeconds > 10) {
      await audioPlayer.seek(Duration.zero);
    } else {
      await audioPlayer.skipToPrevious();
    }
    return null;
  }
}

class StopIntent extends Intent {
  final WidgetRef ref;
  const StopIntent(this.ref);
}

class StopAction extends Action<StopIntent> {
  @override
  invoke(intent) async {
    await intent.ref.read(audioPlayerProvider.notifier).stop();
    return null;
  }
}

class NavigationIntent extends Intent {
  final AppRouter router;
  final String path;
  const NavigationIntent(this.router, this.path);
}

class NavigationAction extends Action<NavigationIntent> {
  @override
  invoke(intent) {
    intent.router.navigateNamed(intent.path);
    return null;
  }
}

enum HomeTabs {
  browse,
  search,

  lyrics,
  userPlaylists,
  userArtists,
  userAlbums,
  userLocalLibrary,
  userDownloads,
}

class HomeTabIntent extends Intent {
  final AppRouter router;
  final HomeTabs tab;
  const HomeTabIntent(this.router, {required this.tab});
}

class HomeTabAction extends Action<HomeTabIntent> {
  @override
  invoke(intent) {
    final router = intent.router;
    switch (intent.tab) {
      case HomeTabs.browse:
        router.navigate(const HomeRoute());
        break;
      case HomeTabs.search:
        router.navigate(const SearchRoute());
        break;
      case HomeTabs.lyrics:
        router.navigate(const LyricsRoute());
        break;
      case HomeTabs.userPlaylists:
        router.navigate(const UserPlaylistsRoute());
        break;
      case HomeTabs.userArtists:
        router.navigate(const UserArtistsRoute());
        break;
      case HomeTabs.userAlbums:
        router.navigate(const UserAlbumsRoute());
        break;
      case HomeTabs.userLocalLibrary:
        router.navigate(const UserLocalLibraryRoute());
        break;
      case HomeTabs.userDownloads:
        router.navigate(const UserDownloadsRoute());
        break;
    }
    return null;
  }
}

class SeekIntent extends Intent {
  final WidgetRef ref;
  final bool forward;
  const SeekIntent(this.ref, this.forward);
}

class SeekAction extends Action<SeekIntent> {
  @override
  invoke(intent) async {
    final isFetchingActiveTrack = intent.ref.read(queryingTrackInfoProvider);
    if (isFetchingActiveTrack) {
      DirectionalFocusAction().invoke(
        DirectionalFocusIntent(
          intent.forward ? TraversalDirection.right : TraversalDirection.left,
        ),
      );
      return null;
    }
    final position = audioPlayer.position.inSeconds;
    await audioPlayer.seek(
      Duration(
        seconds: intent.forward ? position + 5 : position - 5,
      ),
    );
    return null;
  }
}

class CloseAppIntent extends Intent {}

class CloseAppAction extends Action<CloseAppIntent> {
  @override
  invoke(intent) {
    if (kIsDesktop) {
      exit(0);
    } else {
      SystemNavigator.pop();
    }
    return null;
  }
}
