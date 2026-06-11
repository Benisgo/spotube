import 'dart:ui';

import 'package:auto_route/auto_route.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/collections/assets.gen.dart';
import 'package:spotube/collections/intents.dart';
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/components/image/universal_image.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/extensions/duration.dart';
import 'package:spotube/hooks/utils/use_force_update.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/modules/player/use_progress.dart';
import 'package:spotube/pages/lyrics/plain_lyrics.dart';
import 'package:spotube/pages/lyrics/synced_lyrics.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/audio_player/querying_track_info.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/utils/platform.dart';
import 'package:window_manager/window_manager.dart';

@RoutePage()
class MiniLyricsPage extends HookConsumerWidget {
  static const name = "mini_lyrics";

  final Size prevSize;
  const MiniLyricsPage({super.key, required this.prevSize});

  static const Size _compactSize = Size(320, 170);
  static const Size _lyricsSize = Size(320, 340);
  static const Size _minimumMiniSize = Size(260, 120);
  static const Size _minimumLyricsSize = Size(280, 240);

  @override
  Widget build(BuildContext context, ref) {
    final theme = Theme.of(context);
    final update = useForceUpdate();
    final wasMaximized = useRef<bool>(false);

    final playlistQueue = ref.watch(audioPlayerProvider);
    final activeTrack = playlistQueue.activeTrack;
    final isFetchingActiveTrack = ref.watch(queryingTrackInfoProvider);
    final miniPlayerTransparency = ref.watch(
      userPreferencesProvider.select((s) => s.miniPlayerTransparency),
    );
    final playing =
        useStream(audioPlayer.playingStream).data ?? audioPlayer.isPlaying;

    final index = useState(0);

    final areaActive = useState(false);
    final hoverMode = useState(true);
    final showLyrics = useState(false);

    final progress = useProgress(ref);

    useEffect(() {
      if (kIsDesktop) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          wasMaximized.value = await windowManager.isMaximized();
          await windowManager.setMinimumSize(_minimumMiniSize);
          await windowManager.setSize(_compactSize);
        });
      }
      return null;
    }, []);

    return MouseRegion(
      onEnter: !hoverMode.value
          ? null
          : (event) {
              areaActive.value = true;
            },
      onExit: !hoverMode.value
          ? null
          : (event) {
              areaActive.value = false;
            },
      child: _MiniPlayerScaffold(
        theme: theme,
        areaActive: areaActive.value,
        hoverMode: hoverMode.value,
        showLyrics: showLyrics.value,
        index: index.value,
        activeTrack: activeTrack,
        playing: playing,
        isFetchingActiveTrack: isFetchingActiveTrack,
        progress: progress,
        miniPlayerTransparency: miniPlayerTransparency,
        update: update,
        wasMaximized: wasMaximized.value,
        prevSize: prevSize,
        onToggleLyrics: () async {
          showLyrics.value = !showLyrics.value;
          areaActive.value = true;
          hoverMode.value = false;

          if (kIsDesktop) {
            await windowManager.setMinimumSize(
              showLyrics.value ? _minimumLyricsSize : _minimumMiniSize,
            );
            await windowManager.setSize(
              showLyrics.value ? _lyricsSize : _compactSize,
            );
          }
        },
        onToggleHoverMode: () {
          areaActive.value = true;
          hoverMode.value = !hoverMode.value;
        },
        onTabChanged: (value) {
          index.value = value;
        },
      ),
    );
  }
}

class _MiniPlayerScaffold extends ConsumerWidget {
  final ThemeData theme;
  final bool areaActive;
  final bool hoverMode;
  final bool showLyrics;
  final int index;
  final SpotubeTrackObject? activeTrack;
  final bool playing;
  final bool isFetchingActiveTrack;
  final ({
    double progressStatic,
    Duration position,
    Duration duration,
    double bufferProgress
  }) progress;
  final double miniPlayerTransparency;
  final VoidCallback update;
  final bool wasMaximized;
  final Size prevSize;
  final Future<void> Function() onToggleLyrics;
  final VoidCallback onToggleHoverMode;
  final ValueChanged<int> onTabChanged;

  const _MiniPlayerScaffold({
    required this.theme,
    required this.areaActive,
    required this.hoverMode,
    required this.showLyrics,
    required this.index,
    required this.activeTrack,
    required this.playing,
    required this.isFetchingActiveTrack,
    required this.progress,
    required this.miniPlayerTransparency,
    required this.update,
    required this.wasMaximized,
    required this.prevSize,
    required this.onToggleLyrics,
    required this.onToggleHoverMode,
    required this.onTabChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transparency = miniPlayerTransparency.clamp(0.0, 1.0);
    final albumArtOpacity = lerpDouble(0.9, 0.0, transparency) ?? 0.45;
    final panelAlpha = lerpDouble(0.5, 0.01, transparency) ?? 0.12;
    final panelSecondaryAlpha = lerpDouble(0.36, 0.0, transparency) ?? 0.1;
    final toolbarAlpha = lerpDouble(0.56, 0.04, transparency) ?? 0.14;
    final borderAlpha = lerpDouble(0.18, 0.03, transparency) ?? 0.07;
    final shadowAlpha = lerpDouble(0.14, 0.0, transparency) ?? 0.03;

    return Scaffold(
      backgroundColor: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: albumArtOpacity <= 0.01
                  ? const SizedBox.shrink()
                  : Opacity(
                      opacity: albumArtOpacity,
                      child: UniversalImage(
                        path: (activeTrack?.album.images).asUrlString(
                            placeholder: ImagePlaceholder.albumArt),
                        placeholder: Assets.images.albumPlaceholder.path,
                        fit: BoxFit.cover,
                      ),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.black.withValues(alpha: panelAlpha),
                        theme.colorScheme.background.withValues(
                          alpha: panelSecondaryAlpha,
                        ),
                      ],
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: borderAlpha),
                    ),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: shadowAlpha),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                        child: Column(
                          children: [
                            Expanded(
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 220),
                                child: showLyrics
                                    ? _MiniLyricsBody(
                                        index: index,
                                        onTabChanged: onTabChanged,
                                        theme: theme,
                                        showControls: areaActive || !hoverMode,
                                      )
                                    : _MiniPlayerBody(
                                        track: activeTrack,
                                        theme: theme,
                                        playing: playing,
                                        isFetchingActiveTrack:
                                            isFetchingActiveTrack,
                                        progress: progress,
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 200),
                        top: areaActive || !hoverMode ? 8 : -56,
                        right: 8,
                        child: DragToMoveArea(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: theme.colorScheme.background.withValues(
                                alpha: toolbarAlpha,
                              ),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.08),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 4,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Tooltip(
                                    tooltip: TooltipContainer(
                                      child: Text(context.l10n.lyrics),
                                    ).call,
                                    child: IconButton(
                                      variance: showLyrics
                                          ? ButtonVariance.secondary
                                          : ButtonVariance.ghost,
                                      icon: Icon(
                                        showLyrics
                                            ? SpotubeIcons.lyrics
                                            : SpotubeIcons.lyricsOff,
                                      ),
                                      onPressed: onToggleLyrics,
                                    ),
                                  ),
                                  Tooltip(
                                    tooltip: TooltipContainer(
                                      child: Text(
                                        context.l10n.show_hide_ui_on_hover,
                                      ),
                                    ).call,
                                    child: IconButton(
                                      variance: hoverMode
                                          ? ButtonVariance.secondary
                                          : ButtonVariance.ghost,
                                      icon: Icon(
                                        hoverMode
                                            ? SpotubeIcons.hoverOn
                                            : SpotubeIcons.hoverOff,
                                      ),
                                      onPressed: onToggleHoverMode,
                                    ),
                                  ),
                                  if (kIsDesktop)
                                    FutureBuilder(
                                      future: windowManager.isAlwaysOnTop(),
                                      builder: (context, snapshot) {
                                        return Tooltip(
                                          tooltip: TooltipContainer(
                                            child: Text(
                                              context.l10n.always_on_top,
                                            ),
                                          ).call,
                                          child: IconButton(
                                            variance: snapshot.data == true
                                                ? ButtonVariance.secondary
                                                : ButtonVariance.ghost,
                                            icon: Icon(
                                              snapshot.data == true
                                                  ? SpotubeIcons.pinOn
                                                  : SpotubeIcons.pinOff,
                                            ),
                                            onPressed: snapshot.data == null
                                                ? null
                                                : () async {
                                                    await windowManager
                                                        .setAlwaysOnTop(
                                                      snapshot.data == true
                                                          ? false
                                                          : true,
                                                    );
                                                    update();
                                                  },
                                          ),
                                        );
                                      },
                                    ),
                                  Tooltip(
                                    tooltip: TooltipContainer(
                                      child: Text(
                                        context.l10n.exit_mini_player,
                                      ),
                                    ).call,
                                    child: IconButton.ghost(
                                      icon: const Icon(SpotubeIcons.maximize),
                                      onPressed: () async {
                                        if (!kIsDesktop) return;

                                        try {
                                          await windowManager.setMinimumSize(
                                            const Size(300, 700),
                                          );
                                          await windowManager.setAlwaysOnTop(
                                            false,
                                          );
                                          if (wasMaximized) {
                                            await windowManager.maximize();
                                          } else {
                                            await windowManager.setSize(
                                              prevSize,
                                            );
                                          }
                                          await windowManager.setAlignment(
                                            Alignment.center,
                                          );
                                          if (!kIsLinux) {
                                            await windowManager.setHasShadow(
                                              true,
                                            );
                                          }
                                          await Future.delayed(
                                            const Duration(milliseconds: 200),
                                          );
                                        } finally {
                                          if (context.mounted) {
                                            context.navigateTo(
                                              const LyricsRoute(),
                                            );
                                          }
                                        }
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniPlayerBody extends HookConsumerWidget {
  final SpotubeTrackObject? track;
  final ThemeData theme;
  final bool playing;
  final bool isFetchingActiveTrack;
  final ({
    double progressStatic,
    Duration position,
    Duration duration,
    double bufferProgress
  }) progress;

  const _MiniPlayerBody({
    required this.track,
    required this.theme,
    required this.playing,
    required this.isFetchingActiveTrack,
    required this.progress,
  });

  @override
  Widget build(BuildContext context, ref) {
    final progressValue = useState(progress.progressStatic);

    useEffect(() {
      progressValue.value = progress.progressStatic;
      return null;
    }, [progress.progressStatic]);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final ultraCompact = width < 290 || height < 132;
        final compact = width < 330 || height < 152;
        final showAlbumArt = !ultraCompact;
        final showAlbumName = !compact;
        final showTimecodes = !ultraCompact;
        final showSecondaryControls = !compact;
        final topInset = ultraCompact ? 78.0 : 92.0;
        final controlGap = ultraCompact
            ? 2.0
            : compact
                ? 4.0
                : 6.0;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DragToMoveArea(
              child: Padding(
                padding: EdgeInsets.only(right: topInset),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showAlbumArt) ...[
                      _MiniAlbumArt(track: track, compact: compact),
                      Gap(compact ? 8 : 10),
                    ],
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              track?.name ?? context.l10n.not_playing,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: (compact
                                      ? theme.typography.small
                                      : theme.typography.normal)
                                  .copyWith(
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                            const Gap(2),
                            Text(
                              track?.artists.asString() ?? "",
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.typography.small.copyWith(
                                color: Colors.white.withValues(alpha: 0.88),
                              ),
                            ),
                            if (showAlbumName)
                              Text(
                                track?.album.name ?? "",
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.typography.xSmall.copyWith(
                                  color: Colors.white.withValues(alpha: 0.62),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            Slider(
              hintValue: SliderValue.single(progress.bufferProgress),
              value: SliderValue.single(progressValue.value),
              onChanged: isFetchingActiveTrack
                  ? null
                  : (value) {
                      progressValue.value = value.value;
                    },
              onChangeEnd: (value) async {
                await audioPlayer.seek(
                  Duration(
                    seconds:
                        (value.value * progress.duration.inSeconds).toInt(),
                  ),
                );
              },
            ),
            if (showTimecodes)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    progress.position.toHumanReadableString(),
                    style: theme.typography.xSmall.copyWith(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    progress.duration.toHumanReadableString(),
                    style: theme.typography.xSmall.copyWith(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            Gap(showTimecodes ? 4 : 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (showSecondaryControls) ...[
                  Consumer(builder: (context, ref, _) {
                    final shuffled = ref.watch(
                      audioPlayerProvider.select((s) => s.shuffled),
                    );

                    return _MiniControlButton(
                      icon: SpotubeIcons.shuffle,
                      active: shuffled,
                      compact: compact,
                      onPressed: isFetchingActiveTrack
                          ? null
                          : () => audioPlayer.setShuffle(!shuffled),
                    );
                  }),
                  Gap(controlGap),
                ],
                _MiniControlButton(
                  icon: SpotubeIcons.skipBack,
                  compact: compact,
                  onPressed:
                      isFetchingActiveTrack ? null : audioPlayer.skipToPrevious,
                ),
                Gap(controlGap),
                _MiniControlButton(
                  icon: playing ? SpotubeIcons.pause : SpotubeIcons.play,
                  filled: true,
                  compact: compact,
                  loading: isFetchingActiveTrack,
                  onPressed: isFetchingActiveTrack
                      ? null
                      : Actions.handler<PlayPauseIntent>(
                          context,
                          PlayPauseIntent(ref),
                        ),
                ),
                Gap(controlGap),
                _MiniControlButton(
                  icon: SpotubeIcons.skipForward,
                  compact: compact,
                  onPressed:
                      isFetchingActiveTrack ? null : audioPlayer.skipToNext,
                ),
                if (showSecondaryControls) ...[
                  Gap(controlGap),
                  Consumer(builder: (context, ref, _) {
                    final loopMode = ref.watch(
                      audioPlayerProvider.select((s) => s.loopMode),
                    );

                    return _MiniControlButton(
                      icon: loopMode == PlaylistMode.single
                          ? SpotubeIcons.repeatOne
                          : SpotubeIcons.repeat,
                      active: loopMode != PlaylistMode.none,
                      compact: compact,
                      onPressed: isFetchingActiveTrack
                          ? null
                          : () async {
                              await audioPlayer.setLoopMode(
                                switch (loopMode) {
                                  PlaylistMode.loop => PlaylistMode.single,
                                  PlaylistMode.single => PlaylistMode.none,
                                  PlaylistMode.none => PlaylistMode.loop,
                                },
                              );
                            },
                    );
                  }),
                ],
              ],
            ),
          ],
        );
      },
    );
  }
}

class _MiniLyricsBody extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTabChanged;
  final ThemeData theme;
  final bool showControls;

  const _MiniLyricsBody({
    required this.index,
    required this.onTabChanged,
    required this.theme,
    this.showControls = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (showControls) ...[
          Row(
            children: [
              Tabs(
                index: index,
                onChanged: onTabChanged,
                children: [
                  TabItem(child: Text(context.l10n.synced)),
                  TabItem(child: Text(context.l10n.plain)),
                ],
              ),
            ],
          ),
          const Gap(14),
        ],
        Expanded(
          child: IndexedStack(
            index: index,
            children: [
              SyncedLyrics(
                palette: PaletteColor(theme.colorScheme.background, 0),
                isModal: true,
                defaultTextZoom: 65,
                showControls: showControls,
              ),
              PlainLyrics(
                palette: PaletteColor(theme.colorScheme.background, 0),
                isModal: true,
                defaultTextZoom: 65,
                showControls: showControls,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MiniAlbumArt extends StatelessWidget {
  final SpotubeTrackObject? track;
  final bool compact;

  const _MiniAlbumArt({required this.track, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: compact ? 46 : 56,
        height: compact ? 46 : 56,
        child: UniversalImage(
          path: (track?.album.images)
              .asUrlString(placeholder: ImagePlaceholder.albumArt),
          placeholder: Assets.images.albumPlaceholder.path,
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

class _MiniControlButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final bool active;
  final bool filled;
  final bool loading;
  final bool compact;

  const _MiniControlButton({
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.filled = false,
    this.loading = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = filled
        ? theme.colorScheme.background
        : active
            ? theme.colorScheme.primary
            : Colors.white.withValues(alpha: 0.92);

    return IconButton(
      size: compact ? const ButtonSize(0.82) : const ButtonSize(0.95),
      shape: ButtonShape.circle,
      variance:
          filled || active ? ButtonVariance.secondary : ButtonVariance.ghost,
      icon: loading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(),
            )
          : Icon(icon, color: foreground),
      onPressed: onPressed,
    );
  }
}
