import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_undraw/flutter_undraw.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter/shadcn_flutter_extension.dart';
import 'package:spotube/components/fallbacks/error_box.dart';
import 'package:spotube/components/track_presentation/presentation_props.dart';
import 'package:spotube/components/track_presentation/presentation_state.dart';
import 'package:spotube/components/track_presentation/use_track_tile_play_callback.dart';
import 'package:spotube/components/track_tile/track_tile.dart';
import 'package:spotube/components/track_presentation/use_is_user_playlist.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/pages/library/user_local_tracks/user_local_tracks.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';

const _itemExtent = 64.0;
const _pageSize = 50;

/// A static placeholder shown while a tile's data is being fetched.
class _TrackPlaceholder extends StatelessWidget {
  const _TrackPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: theme.borderRadiusMd,
            child: Container(
              width: 44,
              height: 44,
              color: theme.colorScheme.muted,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  height: 12,
                  width: 180,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.muted,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  height: 10,
                  width: 120,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.muted,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ],
            ),
          ),
          Container(
            height: 10,
            width: 32,
            decoration: BoxDecoration(
              color: theme.colorScheme.muted,
              borderRadius: BorderRadius.circular(5),
            ),
          ),
        ],
      ),
    );
  }
}

class PresentationListSection extends HookConsumerWidget {
  const PresentationListSection({super.key});

  /// Fetches one page (offset) from the metadata API and merges results
  /// into [cache], returning false if the fetch failed.
  Future<bool> _loadPageIntoCache(
    WidgetRef ref,
    TrackPresentationOptions options,
    ValueNotifier<Map<int, SpotubeFullTrackObject>> cache,
    int offset,
  ) async {
    final total = options.pagination.total;
    if (total == null) return false;
    final limit = min(_pageSize, total - offset);
    if (limit <= 0) return false;

    try {
      final plugin = await ref.read(metadataPluginProvider.future);
      if (plugin == null) return false;

      final SpotubePaginationResponseObject<SpotubeFullTrackObject> result;
      final collection = options.collection;
      final id = collection is SpotubeSimplePlaylistObject
          ? collection.id
          : (collection as SpotubeSimpleAlbumObject).id;

      if (collection is SpotubeSimplePlaylistObject) {
        result = await plugin.playlist.tracks(
          id,
          offset: offset,
          limit: limit,
        );
      } else {
        result = await plugin.album.tracks(
          id,
          offset: offset,
          limit: limit,
        );
      }

      // Populate the cache in batches of 5 with micro-delays so the
      // frame budget isn't overwhelmed by N simultaneous tile builds.
      var newCache = Map<int, SpotubeFullTrackObject>.from(cache.value);
      for (int i = 0; i < result.items.length; i++) {
        final idx = offset + i;
        if (newCache.containsKey(idx)) continue;
        if (i > 0 && i % 5 == 0) {
          cache.value = newCache;
          newCache = Map<int, SpotubeFullTrackObject>.from(cache.value);
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        newCache[idx] = result.items[i];
      }
      cache.value = newCache;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context, ref) {
    final options = TrackPresentationOptions.of(context);
    final state = ref.watch(presentationStateProvider(options.collection));
    final notifier =
        ref.read(presentationStateProvider(options.collection).notifier);
    final isUserPlaylist = useIsUserPlaylist(ref, options.collectionId);
    final onTileTap = useTrackTilePlayCallback(ref);

    final useVirtualScrolling = options.pagination.total != null &&
        state.searchQuery.isEmpty &&
        state.sortBy == SortBy.none;

    // ------------------------------------------------------------------
    // Random-access track cache (index -> SpotubeFullTrackObject)
    // ------------------------------------------------------------------
    final trackCache = useState(<int, SpotubeFullTrackObject>{});
    final loadingPages = useRef(<int>{});

    ref.watch(metadataPluginProvider);

    // ------------------------------------------------------------------
    // ensurePageLoaded  (called by the tile builder)
    // ------------------------------------------------------------------
    void ensurePageLoaded(int index) {
      if (trackCache.value.containsKey(index)) return;
      if (index < state.presentationTracks.length) return;
      final page = index ~/ _pageSize;
      if (loadingPages.value.contains(page)) return;
      loadingPages.value = {...loadingPages.value, page};

      unawaited(_loadPageIntoCache(ref, options, trackCache, page * _pageSize)
          .then((_) {
        loadingPages.value = {...loadingPages.value}..remove(page);
      }));
    }

    // ------------------------------------------------------------------
    // Track resolver
    // ------------------------------------------------------------------
    SpotubeFullTrackObject? trackAt(int index) {
      if (index < state.presentationTracks.length) {
        return state.presentationTracks[index] as SpotubeFullTrackObject;
      }
      return trackCache.value[index];
    }

    // ------------------------------------------------------------------
    // Empty / error states
    // ------------------------------------------------------------------
    if (state.presentationTracks.isEmpty && !options.pagination.isLoading) {
      if (options.error != null) {
        return SliverToBoxAdapter(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: ErrorBox(
                error: options.error!,
                onRetry: options.pagination.onRefresh,
              ),
            ),
          ),
        );
      }
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Undraw(
                illustration: UndrawIllustration.dreamer,
                color: context.theme.colorScheme.primary,
                height: 200 * context.theme.scaling,
              ),
              Text(
                isUserPlaylist
                    ? context.l10n.no_tracks_added_yet
                    : context.l10n.no_tracks,
                textAlign: TextAlign.center,
              ).muted().small(),
            ],
          ),
        ),
      );
    }

    // ------------------------------------------------------------------
    // Item count – stable when virtual scrolling is active
    // ------------------------------------------------------------------
    final itemCount = useVirtualScrolling
        ? max(options.total, state.presentationTracks.length)
        : state.presentationTracks.length +
            (options.pagination.isLoading ? 1 : 0);

    // ------------------------------------------------------------------
    // The list itself
    // ------------------------------------------------------------------
    return SliverFixedExtentList(
      itemExtent: _itemExtent,
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final track = trackAt(index);

          if (track != null) {
            final isSelected =
                state.selectedTracks.any((e) => e.id == track.id);
            return RepaintBoundary(
              key: ValueKey(track.id),
              child: TrackTile(
                userPlaylist: isUserPlaylist,
                playlistId: options.collectionId,
                index: index,
                track: track,
                selected: isSelected,
                onTap: () => onTileTap(track, index),
                onChanged: state.selectedTracks.isEmpty
                    ? null
                    : (isSelected) {
                        if (isSelected == true) {
                          notifier.selectTrack(track);
                        } else {
                          notifier.deselectTrack(track);
                        }
                      },
                onLongPress: () {
                  notifier.selectTrack(track);
                  HapticFeedback.selectionClick();
                },
              ),
            );
          }

          // ---------------------------------------------------------------
          // Data not yet available — fire a non-sequential page fetch for
          // the page containing this index, and show a placeholder.
          // ---------------------------------------------------------------
          ensurePageLoaded(index);

          return _TrackPlaceholder(key: ValueKey('ph_$index'));
        },
        childCount: itemCount,
      ),
    );
  }
}
