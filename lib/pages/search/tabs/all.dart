import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/components/fallbacks/error_box.dart';
import 'package:spotube/components/inter_scrollbar/inter_scrollbar.dart';
import 'package:spotube/modules/search/loading.dart';
import 'package:spotube/pages/search/search.dart';
import 'package:spotube/modules/search/sections/albums.dart';
import 'package:spotube/modules/search/sections/artists.dart';
import 'package:spotube/modules/search/sections/playlists.dart';
import 'package:spotube/modules/search/sections/tracks.dart';
import 'package:spotube/provider/metadata_plugin/search/all.dart';

class SearchPageAllTab extends HookConsumerWidget {
  const SearchPageAllTab({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final scrollController = useScrollController();
    final searchTerm = ref.watch(searchTermStateProvider);
    final searchSnapshot =
        ref.watch(metadataPluginSearchAllProvider(searchTerm));

    if (searchSnapshot.hasError) {
      return ErrorBox(
        error: searchSnapshot.error!,
        onRetry: () {
          ref.invalidate(metadataPluginSearchAllProvider(searchTerm));
        },
      );
    }

    return SearchPlaceholder(
      snapshot: searchSnapshot,
      child: InterScrollbar(
        controller: scrollController,
        child: CustomScrollView(
          controller: scrollController,
          slivers: const [
            SliverSafeArea(
              sliver: SliverPadding(
                padding: EdgeInsets.symmetric(vertical: 8),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RepaintBoundary(child: SearchTracksSection()),
                      RepaintBoundary(child: SearchPlaylistsSection()),
                      Gap(20),
                      RepaintBoundary(child: SearchArtistsSection()),
                      Gap(20),
                      RepaintBoundary(child: SearchAlbumsSection()),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
