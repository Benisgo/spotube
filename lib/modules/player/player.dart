import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:sliding_up_panel/sliding_up_panel.dart';

import 'package:spotube/collections/assets.gen.dart';
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/components/adaptive/adaptive_pop_sheet_list.dart';
import 'package:spotube/components/framework/app_pop_scope.dart';
import 'package:spotube/components/heart_button/heart_button.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/modules/player/player_actions.dart';
import 'package:spotube/modules/player/player_controls.dart';
import 'package:spotube/modules/player/volume_slider.dart';
import 'package:spotube/components/dialogs/track_details_dialog.dart';
import 'package:spotube/components/links/artist_link.dart';
import 'package:spotube/components/titlebar/titlebar.dart';
import 'package:spotube/components/image/universal_image.dart';
import 'package:spotube/extensions/constrains.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/modules/root/spotube_navigation_bar.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/audio_player/audio_player_service_provider.dart';
import 'package:spotube/provider/metadata_plugin/audio_source/quality_label.dart';
import 'package:spotube/provider/server/active_track_sources.dart';
import 'package:spotube/provider/volume_provider.dart';

class PlayerView extends HookConsumerWidget {
  final PanelController panelController;
  final ScrollController scrollController;
  const PlayerView({
    super.key,
    required this.panelController,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context, ref) {
    final audioPlayer = ref.read(audioPlayerServiceProvider);
    final theme = Theme.of(context);
    final sourcedCurrentTrack = ref.watch(activeTrackSourcesProvider);
    final currentActiveTrack =
        ref.watch(audioPlayerProvider.select((s) => s.activeTrack));
    final currentActiveTrackSource = sourcedCurrentTrack.asData?.value?.source;
    final isLocalTrack = currentActiveTrack is SpotubeLocalTrackObject;
    final mediaQuery = MediaQuery.sizeOf(context);
    final qualityLabel = ref.watch(audioSourceQualityLabelProvider);

    final panelHeight = ref.watch(navigationPanelHeight);
    final shouldHide = useState(panelHeight.ceil() == 75);

    ref.listen(navigationPanelHeight, (_, height) {
      shouldHide.value = height.ceil() == 75;
    });

    if (shouldHide.value) {
      return const SizedBox();
    }

    useEffect(() {
      if (mediaQuery.lgAndUp) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          panelController.close();
        });
      }
      return null;
    }, [mediaQuery.lgAndUp]);

    final tracks = ref.watch(audioPlayerProvider.select((s) => s.tracks));
    final currentIndex =
        ref.watch(audioPlayerProvider.select((s) => s.currentIndex));

    String currentAlbumArt = useMemoized(
      () => (currentActiveTrack?.album.images).asUrlString(
        placeholder: ImagePlaceholder.albumArt,
      ),
      [currentActiveTrack?.album.images],
    );
    String? nextAlbumArt = useMemoized(
      () {
        final nextIdx = currentIndex + 1;
        if (nextIdx >= tracks.length) return null;
        return (tracks[nextIdx].album.images).asUrlString(
          placeholder: ImagePlaceholder.albumArt,
        );
      },
      [currentIndex, tracks.length],
    );
    String? prevAlbumArt = useMemoized(
      () {
        final prevIdx = currentIndex - 1;
        if (prevIdx < 0) return null;
        return (tracks[prevIdx].album.images).asUrlString(
          placeholder: ImagePlaceholder.albumArt,
        );
      },
      [currentIndex],
    );

    useEffect(() {
      for (final renderView in WidgetsBinding.instance.renderViews) {
        renderView.automaticSystemUiAdjustment = false;
      }

      return () {
        for (final renderView in WidgetsBinding.instance.renderViews) {
          renderView.automaticSystemUiAdjustment = true;
        }
      };
    }, [panelController.isAttached && panelController.isPanelOpen]);

    return AppPopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        await panelController.close();
      },
      child: SurfaceCard(
        borderWidth: 0,
        surfaceOpacity: 0.9,
        padding: EdgeInsets.zero,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          headers: [
            SafeArea(
              bottom: false,
              child: TitleBar(
                surfaceOpacity: 0,
                surfaceBlur: 0,
                leading: [
                  IconButton.ghost(
                    size: const ButtonSize(1.2),
                    icon: const Icon(SpotubeIcons.angleDown),
                    onPressed: panelController.close,
                  )
                ],
                title: const Text("Now Playing"),
                trailing: [
                  if (!isLocalTrack) ...[
                    Tooltip(
                      tooltip: TooltipContainer(
                        child: Text(context.l10n.share),
                      ).call,
                      child: IconButton.ghost(
                        size: const ButtonSize(1.2),
                        icon: const Icon(SpotubeIcons.share),
                        onPressed: () {
                          final track = currentActiveTrack;
                          if (track == null) return;
                          Clipboard.setData(
                            ClipboardData(text: track.externalUri),
                          );
                          if (context.mounted) {
                            showToast(
                              context: context,
                              location: ToastLocation.topRight,
                              builder: (context, overlay) {
                                return SurfaceCard(
                                  child: Text(
                                    context.l10n.copied_to_clipboard(
                                      track.externalUri,
                                    ),
                                  ),
                                );
                              },
                            );
                          }
                        },
                      ),
                    ),
                    AdaptivePopSheetList(
                      tooltip: context.l10n.more_actions,
                      offset: const Offset(0, -100),
                      icon: const Icon(SpotubeIcons.moreVertical),
                      onSelected: (value) {
                        if (value == 'details' &&
                            currentActiveTrack != null &&
                            currentActiveTrackSource != null) {
                          showDialog(
                            context: context,
                            builder: (context) => TrackDetailsDialog(
                              track:
                                  currentActiveTrack as SpotubeFullTrackObject,
                            ),
                          );
                        }
                      },
                      items: (context) => [
                        AdaptiveMenuButton(
                          value: 'details',
                          enabled: currentActiveTrackSource != null,
                          child: Text(context.l10n.details),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
          child: mediaQuery.smAndDown
              ? Column(
                  children: [
                    Expanded(
                      flex: 7,
                      child: Center(
                        child: RepaintBoundary(
                          child: _AlbumArtSwipeArea(
                            currentAlbumArt: currentAlbumArt,
                            nextAlbumArt: nextAlbumArt,
                            prevAlbumArt: prevAlbumArt,
                            onSwipeLeft: () => audioPlayer.skipToNext(),
                            onSwipeRight: () => audioPlayer.skipToPrevious(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Tooltip(
                      tooltip: TooltipContainer(
                        child: Text(context.l10n.lyrics),
                      ).call,
                      child: IconButton.ghost(
                        icon: const Icon(SpotubeIcons.music),
                        onPressed: () {
                          context.pushRoute(const PlayerLyricsRoute());
                        },
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      AutoSizeText(
                                        currentActiveTrack?.name ??
                                            context.l10n.not_playing,
                                        style: const TextStyle(fontSize: 22),
                                        maxFontSize: 22,
                                        maxLines: 1,
                                      ),
                                      if (isLocalTrack)
                                        Text(
                                          currentActiveTrack.artists.asString(),
                                          style: theme.typography.normal
                                              .copyWith(
                                                  fontWeight: FontWeight.bold),
                                        )
                                      else
                                        ArtistLink(
                                          artists:
                                              currentActiveTrack?.artists ?? [],
                                          textStyle: theme.typography.normal
                                              .copyWith(
                                                  fontWeight: FontWeight.bold),
                                          onRouteChange: (route) {
                                            panelController.close();
                                            context.router.navigateNamed(route);
                                          },
                                          onOverflowArtistClick: () =>
                                              context.navigateTo(
                                            TrackRoute(
                                              trackId: currentActiveTrack!.id,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                if (currentActiveTrack != null && !isLocalTrack)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 8),
                                    child: TrackHeartButton(
                                      track: currentActiveTrack,
                                      requireAuthentication: false,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const RepaintBoundary(
                              child: PlayerControls(),
                            ),
                            const SizedBox(height: 10),
                            const PlayerActions(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              showQueue: true,
                              showHeart: false,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                )
              : SingleChildScrollView(
                  controller: scrollController,
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Column(
                      children: [
                        RepaintBoundary(
                          child: _AlbumArtSwipeArea(
                            currentAlbumArt: currentAlbumArt,
                            nextAlbumArt: nextAlbumArt,
                            prevAlbumArt: prevAlbumArt,
                            onSwipeLeft: () => audioPlayer.skipToNext(),
                            onSwipeRight: () => audioPlayer.skipToPrevious(),
                          ),
                        ),
                        const SizedBox(height: 40),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AutoSizeText(
                                currentActiveTrack?.name ??
                                    context.l10n.not_playing,
                                style: const TextStyle(fontSize: 22),
                                maxFontSize: 22,
                                maxLines: 1,
                              ),
                              if (isLocalTrack)
                                Text(
                                  currentActiveTrack.artists.asString(),
                                  style: theme.typography.normal
                                      .copyWith(fontWeight: FontWeight.bold),
                                )
                              else
                                ArtistLink(
                                  artists: currentActiveTrack?.artists ?? [],
                                  textStyle: theme.typography.normal
                                      .copyWith(fontWeight: FontWeight.bold),
                                  onRouteChange: (route) {
                                    panelController.close();
                                    context.router.navigateNamed(route);
                                  },
                                  onOverflowArtistClick: () =>
                                      context.navigateTo(
                                    TrackRoute(
                                      trackId: currentActiveTrack!.id,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        const PlayerControls(),
                        const SizedBox(height: 20),
                        const PlayerActions(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          showQueue: true,
                        ),
                        const SizedBox(height: 20),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: RepaintBoundary(
                            child: Consumer(builder: (context, ref, _) {
                              final volume = ref.watch(volumeProvider);
                              return VolumeSlider(
                                fullWidth: true,
                                value: volume,
                                onChanged: (value) {
                                  ref
                                      .read(volumeProvider.notifier)
                                      .setVolume(value);
                                },
                              );
                            }),
                          ),
                        ),
                        const Gap(25),
                        OutlineBadge(
                          style: const ButtonStyle.outline(
                            size: ButtonSize.normal,
                            density: ButtonDensity.dense,
                            shape: ButtonShape.rectangle,
                          ).copyWith(
                            textStyle: (context, states, value) {
                              return value.copyWith(
                                  fontWeight: FontWeight.w500);
                            },
                          ),
                          leading: const Icon(SpotubeIcons.lightningOutlined),
                          child: Text(qualityLabel),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class _AlbumArtSwipeArea extends HookWidget {
  final String currentAlbumArt;
  final String? nextAlbumArt;
  final String? prevAlbumArt;
  final VoidCallback onSwipeLeft;
  final VoidCallback onSwipeRight;

  const _AlbumArtSwipeArea({
    required this.currentAlbumArt,
    this.nextAlbumArt,
    this.prevAlbumArt,
    required this.onSwipeLeft,
    required this.onSwipeRight,
  });

  Widget _buildAlbumArt(String path, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(80),
            spreadRadius: 1,
            blurRadius: 8,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: UniversalImage(
          path: path,
          placeholder: Assets.images.albumPlaceholder.path,
          fit: BoxFit.cover,
          // Decode at display size instead of full-res (640px+) album art —
          // decoding large images on the UI thread is a major Android jank
          // source. CachedNetworkImageProvider resizes via maxWidth/maxHeight.
          width: size,
          height: size,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dragOffset = useState(0.0);
    final isDragging = useState(false);
    final swipeGuard = useRef(false);

    return GestureDetector(
      onHorizontalDragStart: (_) {
        isDragging.value = true;
      },
      onHorizontalDragUpdate: (details) {
        dragOffset.value =
            (dragOffset.value + details.delta.dx).clamp(-200.0, 200.0);
      },
      onHorizontalDragEnd: (details) {
        if (swipeGuard.value) return;
        const threshold = 80.0;
        if (dragOffset.value < -threshold) {
          swipeGuard.value = true;
          onSwipeLeft();
          Future.delayed(const Duration(milliseconds: 300), () {
            swipeGuard.value = false;
          });
        } else if (dragOffset.value > threshold) {
          swipeGuard.value = true;
          onSwipeRight();
          Future.delayed(const Duration(milliseconds: 300), () {
            swipeGuard.value = false;
          });
        }
        dragOffset.value = 0.0;
        isDragging.value = false;
      },
      onHorizontalDragCancel: () {
        dragOffset.value = 0.0;
        isDragging.value = false;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Size the album art to BOTH available width and height so it
          // shrinks in short/narrow windows (e.g. split-screen) instead of a
          // fixed 200-320px square that squeezes out the controls.
          final size = math.min(
            constraints.maxWidth.clamp(140.0, 320.0),
            constraints.maxHeight,
          );
          return SizedBox(
            width: size,
            height: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (dragOffset.value > 0 && prevAlbumArt != null)
                  Transform.translate(
                    offset: Offset(-280 + dragOffset.value, 0),
                    child: Opacity(
                      opacity: ((dragOffset.value - 20) / 200).clamp(0.0, 1.0),
                      child: _buildAlbumArt(prevAlbumArt!, size),
                    ),
                  ),
                if (dragOffset.value < 0 && nextAlbumArt != null)
                  Transform.translate(
                    offset: Offset(280 + dragOffset.value, 0),
                    child: Opacity(
                      opacity:
                          (((-dragOffset.value) - 20) / 200).clamp(0.0, 1.0),
                      child: _buildAlbumArt(nextAlbumArt!, size),
                    ),
                  ),
                AnimatedContainer(
                  duration: Duration(
                    milliseconds: isDragging.value ? 0 : 250,
                  ),
                  curve: Curves.easeInOut,
                  transform: Matrix4.translationValues(dragOffset.value, 0, 0),
                  child: _buildAlbumArt(currentAlbumArt, size),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
