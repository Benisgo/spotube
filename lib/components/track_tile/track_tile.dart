import 'package:auto_route/auto_route.dart';
import 'package:flutter/gestures.dart';

import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/components/dialogs/track_preview_dialog.dart';
import 'package:spotube/components/hover_builder.dart';
import 'package:spotube/components/image/universal_image.dart';
import 'package:spotube/components/links/artist_link.dart';
import 'package:spotube/components/links/link_text.dart';
import 'package:spotube/components/track_tile/track_options_button.dart';
import 'package:spotube/components/ui/button_tile.dart';
import 'package:spotube/extensions/constrains.dart';
import 'package:spotube/extensions/duration.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/models/multi_session/multi_session.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/audio_player/querying_track_info.dart';
import 'package:spotube/provider/blacklist_provider.dart';
import 'package:spotube/provider/connectivity_provider.dart';
import 'package:spotube/provider/multi_session/multi_session.dart';
import 'package:spotube/services/connectivity_adapter.dart';
import 'package:spotube/services/sourced_track/sourced_track.dart';
import 'package:spotube/utils/platform.dart';

final isTrackAudioCachedProvider =
    FutureProvider.family<bool, SpotubeTrackObject>((ref, track) async {
  if (track is SpotubeLocalTrackObject) return true;
  if (track is! SpotubeFullTrackObject) return false;
  try {
    final cachedFile = await SourcedTrack.findLocalCachedFile(track);
    return cachedFile != null;
  } catch (_) {
    return false;
  }
});

final isBlacklistedProvider =
    Provider.autoDispose.family<bool, SpotubeTrackObject>(
  (ref, track) {
    ref.watch(blacklistProvider);
    final blacklist = ref.read(blacklistProvider.notifier);
    return blacklist.contains(track);
  },
);

final _overlay = ValueNotifier<OverlayCompleter<dynamic>?>(null);

class TrackTile extends HookConsumerWidget {
  final int? index;
  final SpotubeTrackObject track;
  final bool selected;
  final bool selectionMode;
  final ValueChanged<bool?>? onChanged;
  final Future<void> Function()? onTap;
  final VoidCallback? onLongPress;
  final bool userPlaylist;
  final String? playlistId;
  final bool compact;
  final bool isFetchingActiveTrack;
  final List<Widget>? leadingActions;
  final Widget? trailingExtra;

  const TrackTile({
    super.key,
    this.index,
    required this.track,
    this.selected = false,
    this.selectionMode = false,
    this.onTap,
    this.onLongPress,
    this.onChanged,
    this.userPlaylist = false,
    this.playlistId,
    this.compact = false,
    this.isFetchingActiveTrack = false,
    this.leadingActions,
    this.trailingExtra,
  });

  @override
  Widget build(BuildContext context, ref) {
    final theme = Theme.of(context);

    final isBlackListed = ref.watch(
      blacklistProvider.select(
        (blacklist) =>
            blacklist.asData?.value.any(
              (element) =>
                  element.elementId == track.id ||
                  track.artists.any((a) => element.elementId == a.id),
            ) ??
            false,
      ),
    );
    final isPlaying = ref.watch(
      audioPlayerProvider.select((value) => value.activeTrack?.id == track.id),
    );
    // Narrow subscription: rebuild only when THIS track's pending status changes,
    // not when any other track becomes pending.
    final isPendingPlayback = ref.watch(
      pendingPlaybackTrackIdProvider
          .select((id) => id == track.id && !isPlaying),
    );
    final isTrackQuerying =
        isFetchingActiveTrack || ref.watch(trackQueryingInfoProvider(track));
    final isSelected = isPlaying || isPendingPlayback;
    final effectiveSelection = selectionMode || onChanged != null;

    final isListener = ref.watch(
      multiSessionProvider.select(
        (s) => s.connected && !s.can(MultiSessionPermission.controlPlayback),
      ),
    );

    final isOnline = ref.watch(connectivityProvider).value ??
        ConnectionCheckerService.instance.isConnectedSync;
    final isOffline = !isOnline;
    final isAudioCached = !isOffline
        ? true
        : (ref.watch(isTrackAudioCachedProvider(track)).asData?.value ?? true);
    final isDimmed = isOffline && !isAudioCached;

    final mediaQuery = MediaQuery.sizeOf(context);

    final durationString = useMemoized(
      () => Duration(milliseconds: track.durationMs)
          .toHumanReadableString(padZero: false),
      [track.durationMs],
    );

    // AnimatedOpacity at opacity 1.0 is a zero-cost no-op in the engine
    // (no saveLayer created). Opacity widget always allocates a compositing
    // layer even at 1.0, causing ~98ms raster spikes on scroll.
    return AnimatedOpacity(
      opacity: isDimmed ? 0.45 : 1.0,
      duration: Duration.zero,
      child: Listener(
        onPointerDown: (event) {
          if (event.buttons != kSecondaryMouseButton) return;
          if (_overlay.value != null) {
            _overlay.value?.remove();
            _overlay.value = null;
          }
          _overlay.value = TrackOptionsButton.showOptions(
            context,
            Offset.zero,
            track,
            userPlaylist: userPlaylist,
            playlistId: playlistId,
          );
        },
        child: HoverBuilder(
          permanentState: isSelected || mediaQuery.smAndDown ? true : null,
          builder: (context, isHovering) => ButtonTile(
            selected: isSelected,
            onPressed: () async {
              if (isBlackListed) return;
              if (isListener) {
                await showDialog<void>(
                  context: context,
                  builder: (context) => TrackPreviewDialog(track: track),
                );
                return;
              }
              try {
                await onTap?.call();
              } catch (e) {
                if (context.mounted && isOffline) {
                  showToast(
                    context: context,
                    builder: (context, overlay) => SurfaceCard(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          "Track '${track.name}' is not cached for offline playback.",
                        ),
                      ),
                    ),
                  );
                }
              }
            },
            onLongPress: onLongPress,
            style: (isBlackListed
                    ? ButtonVariance.destructive
                    : ButtonVariance.ghost)
                .copyWith(
              padding: (context, states, value) =>
                  const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
            ),
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...?leadingActions,
                // Direct conditional (was AnimatedCrossFade): builds only ONE
                // child and holds no AnimationController, so scroll-fling
                // row builds stay cheap.
                if (index != null && onChanged == null)
                  mediaQuery.smAndDown
                      ? const SizedBox(width: 16)
                      : SizedBox(
                          width: 50,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Text(
                              '${(index ?? 0) + 1}',
                              maxLines: 1,
                              style: theme.typography.small,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                else
                  Checkbox(
                    state: selected
                        ? CheckboxState.checked
                        : CheckboxState.unchecked,
                    onChanged: (state) =>
                        onChanged?.call(state == CheckboxState.checked),
                  ),
                _TrackTileArtOverlay(
                  track: track,
                  isPlaying: isPlaying,
                  isHovering: isHovering,
                  isPendingPlayback: isPendingPlayback,
                  isTrackQuerying: isTrackQuerying,
                ),
              ],
            ),
            title: Row(
              children: [
                Expanded(
                  flex: mediaQuery.lgAndUp ? 5 : 6,
                  child: AbsorbPointer(
                    absorbing: selectionMode,
                    child: switch (track) {
                      SpotubeLocalTrackObject() => Text(
                          track.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      _ => Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Button(
                                style: ButtonVariance.link.copyWith(
                                  padding: (context, states, value) =>
                                      EdgeInsets.zero,
                                ),
                                onPressed: effectiveSelection
                                    ? null
                                    : () {
                                        context.navigateTo(
                                          TrackRoute(trackId: track.id),
                                        );
                                      },
                                child: Text(
                                  track.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                        ),
                    },
                  ),
                ),
                if (mediaQuery.mdAndUp) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 4,
                    child: compact
                        ? Text(
                            track.album.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : switch (track) {
                            SpotubeLocalTrackObject() => Text(
                                track.album.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            _ => Align(
                                alignment: Alignment.centerLeft,
                                child: LinkText(
                                  track.album.name,
                                  AlbumRoute(
                                    album: track.album,
                                    id: track.album.id,
                                  ),
                                  push: true,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          },
                  ),
                ],
              ],
            ),
            subtitle: Align(
              alignment: Alignment.centerLeft,
              child: compact || track is SpotubeLocalTrackObject
                  ? Text(
                      track.artists.asString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  : ClipRect(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 40),
                        child: AbsorbPointer(
                          absorbing: effectiveSelection,
                          child: ArtistLink(
                            artists: track.artists,
                            onOverflowArtistClick: effectiveSelection
                                ? () {}
                                : () {
                                    context.navigateTo(
                                      TrackRoute(trackId: track.id),
                                    );
                                  },
                          ),
                        ),
                      ),
                    ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 8),
                if (trailingExtra != null) ...[
                  trailingExtra!,
                  const SizedBox(width: 8),
                ],
                Text(
                  durationString,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                TrackOptionsButton(
                  track: track,
                  userPlaylist: userPlaylist,
                  playlistId: playlistId,
                ),
                if (kIsDesktop) const Gap(10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Scoped widget for the album art overlay. `isPlaying` is passed from the
/// parent TrackTile (which already watches activeTrackId) so the overlay
/// itself holds no provider subscription.
class _TrackTileArtOverlay extends StatelessWidget {
  final SpotubeTrackObject track;
  final bool isPlaying;
  final bool isHovering;
  final bool isPendingPlayback;
  final bool isTrackQuerying;

  const _TrackTileArtOverlay({
    required this.track,
    required this.isPlaying,
    required this.isHovering,
    required this.isPendingPlayback,
    required this.isTrackQuerying,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imagePath = (track.album.images).smallest(ImagePlaceholder.albumArt);

    return Stack(
      children: [
        // Use DecorationImage instead of ClipRRect+UniversalImage.
        // ClipRRect forces a GPU compositing saveLayer on every scroll frame.
        // DecorationImage clips via canvas paint ops on the same raster layer —
        // no extra compositing buffer allocation.
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: theme.borderRadiusMd,
            image: DecorationImage(
              image: UniversalImage.imageProvider(
                imagePath,
                height: 40,
                width: 40,
              ),
              fit: BoxFit.cover,
              filterQuality: FilterQuality.low,
            ),
          ),
          child: const SizedBox(width: 40, height: 40),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: theme.borderRadiusMd,
              color:
                  isHovering ? Colors.black.withAlpha(102) : Colors.transparent,
            ),
          ),
        ),
        Positioned.fill(
          child: Center(
            child: Skeleton.ignore(
              child: switch ((
                isPlaying,
                isTrackQuerying,
                isHovering,
                isPendingPlayback,
              )) {
                (true, true, _, _) || (_, _, _, true) => const SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(),
                  ),
                (true, _, _, _) => Icon(
                    SpotubeIcons.pause,
                    color: theme.colorScheme.primary,
                  ),
                (_, _, true, _) => const Icon(
                    SpotubeIcons.play,
                    color: Colors.white,
                  ),
                _ => const SizedBox.shrink(),
              },
            ),
          ),
        ),
      ],
    );
  }
}
