import 'dart:async';

import 'package:flutter/material.dart' as material;
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/collections/assets.gen.dart';
import 'package:spotube/components/track_presentation/presentation_props.dart';
import 'package:spotube/components/track_presentation/track_presentation.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/pages/playlist/playlist.dart';
import 'package:spotube/provider/metadata_plugin/library/tracks.dart';
import 'package:auto_route/auto_route.dart';
import 'package:spotube/provider/metadata_plugin/utils/common.dart';

@RoutePage()
class LikedPlaylistPage extends HookConsumerWidget {
  static const name = PlaylistPage.name;

  final SpotubeSimplePlaylistObject playlist;
  const LikedPlaylistPage({
    super.key,
    required this.playlist,
  });

  @override
  Widget build(BuildContext context, ref) {
    final likedTracks = ref.watch(metadataPluginSavedTracksProvider);
    final likedTracksNotifier =
        ref.watch(metadataPluginSavedTracksProvider.notifier);
    final tracks = likedTracks.asData?.value.items ?? [];

    useEffect(() {
      if (likedTracks.asData?.value.hasMore == true) {
        Future<void>.delayed(Duration.zero, () async {
          await likedTracksNotifier.fetchAll();
        });
      }
      return null;
    }, [likedTracks.asData?.value.hasMore, likedTracksNotifier]);

    return material.RefreshIndicator.adaptive(
      onRefresh: () async {
        resetSavedTracksFetchProgress(ref);
        ref.invalidate(metadataPluginSavedTracksProvider);
      },
      child: TrackPresentation(
        options: TrackPresentationOptions(
          collection: playlist,
          image: Assets.images.likedTracks.path,
          pagination: PaginationProps(
            hasNextPage: likedTracks.asData?.value.hasMore ?? false,
            isLoading: likedTracks.isLoadingNextPage && !likedTracks.isLoading,
            total: likedTracks.asData?.value.total,
            onFetchMore: () async {
              await likedTracksNotifier.fetchMore();
            },
            onFetchAll: () async {
              return await likedTracksNotifier.fetchAll();
            },
            onRefresh: () async {
              resetSavedTracksFetchProgress(ref);
              ref.invalidate(metadataPluginSavedTracksProvider);
            },
          ),
          title: playlist.name,
          description: playlist.description,
          tracks: tracks,
          error: likedTracks.error,
          routePath: '/playlist/${playlist.id}',
          isLiked: false,
          shareUrl: null,
          onHeart: null,
          owner: playlist.owner.name,
        ),
      ),
    );
  }
}
