import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/collections/intents.dart';
import 'package:spotube/extensions/constrains.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/extensions/duration.dart';
import 'package:spotube/models/multi_session/multi_session.dart';
import 'package:spotube/modules/player/use_progress.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/audio_player/audio_player_service_provider.dart';
import 'package:spotube/provider/audio_player/querying_track_info.dart';
import 'package:spotube/provider/multi_session/multi_session.dart';
import 'package:spotube/utils/platform.dart';

class PlayerControls extends HookConsumerWidget {
  final PaletteGenerator? palette;
  final bool compact;

  const PlayerControls({
    this.palette,
    this.compact = false,
    super.key,
  });

  static FocusNode focusNode = FocusNode();

  @override
  Widget build(BuildContext context, ref) {
    final audioPlayer = ref.read(audioPlayerServiceProvider);
    final shortcuts = useMemoized(
        () => {
              const SingleActivator(LogicalKeyboardKey.arrowRight):
                  SeekIntent(ref, true),
              const SingleActivator(LogicalKeyboardKey.arrowLeft):
                  SeekIntent(ref, false),
            },
        [ref]);
    final actions = useMemoized(
        () => {
              SeekIntent: SeekAction(),
            },
        []);
    final isFetchingActiveTrack = ref.watch(queryingTrackInfoProvider);

    final playing =
        useStream(audioPlayer.playingStream).data ?? audioPlayer.isPlaying;

    final multiSession = ref.watch(multiSessionProvider);
    final isListener = multiSession.connected &&
        !multiSession.can(MultiSessionPermission.controlPlayback);
    final displayPlaying = playing && !multiSession.locallyMuted;
    final theme = Theme.of(context);

    void showNoPreviousTrackToast() {
      showToast(
        context: context,
        location: ToastLocation.bottomCenter,
        builder: (context, overlay) {
          return const SurfaceCard(
            child: Basic(
              leading: Icon(SpotubeIcons.skipBack),
              title: Text("There is no previous track to go back to."),
            ),
          );
        },
      );
    }

    final buttonSize =
        kIsMobile ? const ButtonSize(1.5) : const ButtonSize(1.2);

    final glowController = useAnimationController(
      duration: const Duration(milliseconds: 1500),
    );

    // Only run the pulse glow while actually playing, and scope it below with
    // AnimatedBuilder so it rebuilds just the play button — NOT the whole
    // controls subtree every frame (this was a major rebuild storm in the
    // profile: PlayerControls rebuilt ~every frame).
    useEffect(() {
      if (displayPlaying) {
        glowController.repeat(reverse: true);
      } else {
        glowController.stop();
      }
      return null;
    }, [displayPlaying]);

    final lastSkipCall = useRef<DateTime?>(null);
    void debouncedSkip(void Function() fn) {
      final now = DateTime.now();
      if (lastSkipCall.value != null &&
          now.difference(lastSkipCall.value!) <
              const Duration(milliseconds: 300)) {
        return;
      }
      lastSkipCall.value = now;
      fn();
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        if (focusNode.canRequestFocus) {
          focusNode.requestFocus();
        }
      },
      child: FocusableActionDetector(
        focusNode: focusNode,
        shortcuts: shortcuts,
        actions: actions,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            children: [
              if (!compact)
                HookBuilder(
                  builder: (context) {
                    final mediaQuery = MediaQuery.sizeOf(context);

                    final (
                      :bufferProgress,
                      :duration,
                      :position,
                      :progressStatic
                    ) = useProgress(ref);

                    final progress = useState<num>(
                      useMemoized(() => progressStatic, []),
                    );

                    useEffect(() {
                      progress.value = progressStatic;
                      return null;
                    }, [progressStatic]);

                    return Column(
                      children: [
                        Tooltip(
                          tooltip: TooltipContainer(
                            child: Text(context.l10n.slide_to_seek),
                          ).call,
                          child: SizedBox(
                            width: math.min(
                              mediaQuery.xlAndUp ? 600 : 500,
                              mediaQuery.width,
                            ),
                            child: Slider(
                              hintValue: SliderValue.single(bufferProgress),
                              value:
                                  SliderValue.single(progress.value.toDouble()),
                              onChanged: null,
                              onChangeEnd: (value) async {
                                final clamped = value.value.clamp(0.0, 1.0);
                                await audioPlayer.seek(
                                  Duration(
                                    seconds:
                                        (clamped * duration.inSeconds).toInt(),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8.0,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                position.toHumanReadableString(),
                                style: theme.typography.xSmall,
                              ),
                              Text(
                                duration.toHumanReadableString(),
                                style: theme.typography.xSmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Hide shuffle button entirely when in a multi-session
                  // room — shuffle is synced from the host (Bug B1).
                  if (!multiSession.connected)
                    Consumer(builder: (context, ref, _) {
                      final shuffled = ref
                          .watch(audioPlayerProvider.select((s) => s.shuffled));
                      return Tooltip(
                        tooltip: TooltipContainer(
                          child: Text(
                            shuffled
                                ? context.l10n.unshuffle_playlist
                                : context.l10n.shuffle_playlist,
                          ),
                        ).call,
                        child: IconButton(
                          size: buttonSize,
                          icon: Icon(
                            SpotubeIcons.shuffle,
                            color: shuffled ? theme.colorScheme.primary : null,
                            size: 22,
                          ),
                          variance: shuffled
                              ? ButtonVariance.secondary
                              : ButtonVariance.ghost,
                          onPressed: isFetchingActiveTrack
                              ? null
                              : () {
                                  if (shuffled) {
                                    audioPlayer.setShuffle(false);
                                  } else {
                                    audioPlayer.setShuffle(true);
                                  }
                                },
                        ),
                      );
                    }),
                  if (!isListener)
                    Tooltip(
                      tooltip: TooltipContainer(
                        child: Text(context.l10n.previous_track),
                      ).call,
                      child: IconButton.ghost(
                        size: buttonSize,
                        enabled: !isFetchingActiveTrack,
                        icon: const Icon(SpotubeIcons.skipBack),
                        onPressed: () {
                          debouncedSkip(() {
                            if (audioPlayer.position.inSeconds > 10) {
                              audioPlayer.seek(Duration.zero);
                              return;
                            }
                            if (!audioPlayer.canSkipToPrevious) {
                              showNoPreviousTrackToast();
                              return;
                            }
                            audioPlayer.skipToPrevious();
                          });
                        },
                      ),
                    ),
                  Tooltip(
                    tooltip: TooltipContainer(
                      child: Text(
                        displayPlaying
                            ? context.l10n.pause_playback
                            : context.l10n.resume_playback,
                      ),
                    ).call,
                    child: AnimatedBuilder(
                      animation: glowController,
                      builder: (context, _) {
                        final glow = glowController.value;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: displayPlaying
                                ? [
                                    BoxShadow(
                                      color:
                                          theme.colorScheme.primary.withValues(
                                        alpha: (0.3 + (0.2 * glow)).toDouble(),
                                      ),
                                      blurRadius: 10 + (10 * glow),
                                      spreadRadius: 2 + (4 * glow),
                                    )
                                  ]
                                : [],
                          ),
                          child: IconButton.primary(
                            size: buttonSize,
                            shape: ButtonShape.circle,
                            icon: isFetchingActiveTrack
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(),
                                  )
                                : Icon(
                                    displayPlaying
                                        ? SpotubeIcons.pause
                                        : SpotubeIcons.play,
                                  ),
                            onPressed: isFetchingActiveTrack
                                ? null
                                : Actions.handler<PlayPauseIntent>(
                                    context,
                                    PlayPauseIntent(ref),
                                  ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (!isListener)
                    Tooltip(
                      tooltip:
                          TooltipContainer(child: Text(context.l10n.next_track))
                              .call,
                      child: IconButton.ghost(
                        size: buttonSize,
                        icon: const Icon(SpotubeIcons.skipForward),
                        onPressed: isFetchingActiveTrack
                            ? null
                            : () => debouncedSkip(audioPlayer.skipToNext),
                      ),
                    ),
                  if (!isListener)
                    Consumer(builder: (context, ref, _) {
                      final loopMode = ref
                          .watch(audioPlayerProvider.select((s) => s.loopMode));

                      return Tooltip(
                        tooltip: TooltipContainer(
                          child: Text(
                            loopMode == PlaylistMode.single
                                ? context.l10n.loop_track
                                : loopMode == PlaylistMode.loop
                                    ? context.l10n.repeat_playlist
                                    : "",
                          ),
                        ).call,
                        child: IconButton(
                          size: buttonSize,
                          icon: Icon(
                            loopMode == PlaylistMode.single
                                ? SpotubeIcons.repeatOne
                                : SpotubeIcons.repeat,
                            color: loopMode != PlaylistMode.none
                                ? theme.colorScheme.primary
                                : null,
                          ),
                          variance: loopMode == PlaylistMode.single ||
                                  loopMode == PlaylistMode.loop
                              ? ButtonVariance.secondary
                              : ButtonVariance.ghost,
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
                        ),
                      );
                    }),
                ],
              ),
              const SizedBox(height: 5)
            ],
          ),
        ),
      ),
    );
  }
}
