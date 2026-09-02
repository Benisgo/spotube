import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:sliding_up_panel/sliding_up_panel.dart';
import 'package:spotube/collections/intents.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/models/multi_session/multi_session.dart';
import 'package:spotube/modules/player/player_track_details.dart';
import 'package:spotube/modules/root/spotube_navigation_bar.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/audio_player/audio_player_service_provider.dart';
import 'package:spotube/provider/audio_player/querying_track_info.dart';
import 'package:spotube/provider/multi_session/multi_session.dart';

class PlayerOverlayCollapsedSection extends HookConsumerWidget {
  final PanelController panelController;
  const PlayerOverlayCollapsedSection({
    super.key,
    required this.panelController,
  });

  @override
  Widget build(BuildContext context, ref) {
    final audioPlayer = ref.read(audioPlayerServiceProvider);
    final activeTrack = ref.watch(
      audioPlayerProvider.select((s) => s.activeTrack),
    );
    final canShow = activeTrack != null;

    final isFetchingActiveTrack = ref.watch(queryingTrackInfoProvider);
    final playing =
        useStream(audioPlayer.playingStream).data ?? audioPlayer.isPlaying;

    final isListener = ref.watch(
      multiSessionProvider.select(
        (s) => s.connected && !s.can(MultiSessionPermission.controlPlayback),
      ),
    );
    final displayPlaying = playing &&
        !ref.watch(
          multiSessionProvider.select((s) => s.locallyMuted),
        );

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

    final shouldShow = useState(true);

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

    ref.listen(navigationPanelHeight, (_, height) {
      shouldShow.value = height.ceil() == 75;
    });

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: canShow && shouldShow.value
          ? RepaintBoundary(
              child: Padding(
              padding: const EdgeInsets.all(5),
              child: SurfaceCard(
                surfaceBlur: theme.surfaceBlur,
                surfaceOpacity: theme.surfaceOpacity,
                padding: EdgeInsets.zero,
                borderRadius: theme.borderRadiusLg,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ... (rest unchanged)
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                panelController.open();
                              },
                              onVerticalDragEnd: (details) {
                                if (details.primaryVelocity != null &&
                                    details.primaryVelocity! < -100) {
                                  panelController.open();
                                }
                              },
                              child: Container(
                                width: double.infinity,
                                color: Colors.transparent,
                                child: PlayerTrackDetails(
                                  track: activeTrack,
                                  color: theme.colorScheme.foreground,
                                ),
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              if (!isListener)
                                IconButton.ghost(
                                  icon: const Icon(SpotubeIcons.skipBack),
                                  onPressed: isFetchingActiveTrack
                                      ? null
                                      : () => debouncedSkip(() {
                                            if (audioPlayer.position.inSeconds >
                                                10) {
                                              audioPlayer.seek(Duration.zero);
                                              return;
                                            }
                                            if (!audioPlayer
                                                .canSkipToPrevious) {
                                              showNoPreviousTrackToast();
                                              return;
                                            }
                                            audioPlayer.skipToPrevious();
                                          }),
                                ),
                              Consumer(
                                builder: (context, ref, _) {
                                  return IconButton.ghost(
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
                                    onPressed: Actions.handler<PlayPauseIntent>(
                                      context,
                                      PlayPauseIntent(ref),
                                    ),
                                  );
                                },
                              ),
                              if (!isListener)
                                IconButton.ghost(
                                  icon: const Icon(SpotubeIcons.skipForward),
                                  onPressed: isFetchingActiveTrack
                                      ? null
                                      : () =>
                                          debouncedSkip(audioPlayer.skipToNext),
                                ),
                              const Gap(5),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ))
          : const SizedBox.shrink(),
    );
  }
}
