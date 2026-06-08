import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/collections/routes.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/models/multi_session/multi_session.dart';
import 'package:spotube/provider/metadata_plugin/album/album.dart';
import 'package:spotube/provider/metadata_plugin/playlist/playlist.dart';
import 'package:spotube/provider/multi_session/multi_session.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/utils/spotify_link.dart';

final appLinks = AppLinks();
final linkStream = appLinks.stringLinkStream.asBroadcastStream();

void useDeepLinking(WidgetRef ref, AppRouter router) {
  useEffect(() {
    Future<void> handleLink(String? uriString, {String source = 'stream'}) async {
      try {
        AppLogger.log.i("DeepLink [$source]: received '$uriString'");
        if (uriString == null || uriString.isEmpty) {
          AppLogger.log.w("DeepLink [$source]: empty or null, skipping");
          return;
        }

        // Try multi-session invite first
        final invite = parseMultiSessionInviteUri(uriString);
        if (invite != null) {
          AppLogger.log.i("DeepLink [$source]: multi-session invite detected");
          await ref
              .read(multiSessionProvider.notifier)
              .resolveInviteUri(uriString);
          final rootContext = rootNavigatorKey.currentContext;
          if (rootContext == null || !rootContext.mounted) return;
          router.navigate(const ConnectRoute());
          return;
        }

        // Try Spotify link
        final spotifyLink = parseSpotifyLink(uriString);
        if (spotifyLink == null) {
          AppLogger.log.w("DeepLink [$source]: not a recognized link format");
          return;
        }
        AppLogger.log.i("DeepLink [$source]: parsed as ${spotifyLink.type}/${spotifyLink.id}");

        final enabled = ref.read(userPreferencesProvider).handleSpotifyLinks;
        if (!enabled) {
          AppLogger.log.i("DeepLink [$source]: Spotify link handling disabled in settings");
          return;
        }

        final rootContext = rootNavigatorKey.currentContext;
        if (rootContext == null || !rootContext.mounted) {
          AppLogger.log.w("DeepLink [$source]: rootContext not available");
          return;
        }

        AppLogger.log.i("DeepLink [$source]: navigating to ${spotifyLink.type}/${spotifyLink.id}");

        switch (spotifyLink.type) {
          case SpotifyContentType.track:
            router.navigate(TrackRoute(trackId: spotifyLink.id));
          case SpotifyContentType.artist:
            router.navigate(ArtistRoute(artistId: spotifyLink.id));
          case SpotifyContentType.album:
            final album = await ref.read(
              metadataPluginAlbumProvider(spotifyLink.id).future,
            );
            router.navigate(AlbumRoute(
              id: spotifyLink.id,
              album: SpotubeSimpleAlbumObject(
                id: album.id,
                name: album.name,
                externalUri: album.externalUri,
                artists: album.artists,
                images: album.images,
                albumType: album.albumType,
                releaseDate: album.releaseDate,
              ),
            ));
          case SpotifyContentType.playlist:
            final playlist = await ref.read(
              metadataPluginPlaylistProvider(spotifyLink.id).future,
            );
            router.navigate(PlaylistRoute(
              id: spotifyLink.id,
              playlist: SpotubeSimplePlaylistObject(
                id: playlist.id,
                name: playlist.name,
                description: playlist.description,
                externalUri: playlist.externalUri,
                owner: playlist.owner,
                images: playlist.images,
              ),
            ));
        }
      } catch (e, stack) {
        AppLogger.log.e("DeepLink [$source]: error: $e");
        AppLogger.reportError(e, stack);
      }
    }

    final subscription = linkStream.listen((uri) {
      handleLink(uri, source: 'stream');
    });

    appLinks.getInitialLinkString().then((uri) {
      handleLink(uri, source: 'initial');
    });

    return subscription.cancel;
  }, [ref, router]);
}
