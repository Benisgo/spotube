import 'package:auto_route/auto_route.dart';
import 'package:flutter/gestures.dart';

import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:spotube/services/audio_player/audio_player.dart';

import 'package:spotube/collections/assets.gen.dart';
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/components/image/universal_image.dart';
import 'package:spotube/components/links/artist_link.dart';
import 'package:spotube/components/links/link_text.dart';
import 'package:spotube/components/track_tile/track_options_button.dart';
import 'package:spotube/extensions/constrains.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';

final _playerDetailsOverlay = ValueNotifier<OverlayCompleter<dynamic>?>(null);

class PlayerTrackDetails extends HookConsumerWidget {
  final Color? color;
  final SpotubeTrackObject? track;
  const PlayerTrackDetails({super.key, this.color, this.track});

  @override
  Widget build(BuildContext context, ref) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final activeTrack = ref.watch(
      audioPlayerProvider.select((s) => s.activeTrack),
    );
    final playing =
        useStream(audioPlayer.playingStream).data ?? audioPlayer.isPlaying;

    final glowController = useAnimationController(
      duration: const Duration(milliseconds: 2000),
    );

    useEffect(() {
      if (playing) {
        glowController.repeat(reverse: true);
      } else {
        glowController.animateTo(0.0,
            duration: const Duration(milliseconds: 500));
      }
      return null;
    }, [playing]);

    return Listener(
      onPointerDown: (event) {
        if (event.buttons != kSecondaryMouseButton) return;
        if (activeTrack == null) return;
        if (_playerDetailsOverlay.value != null) {
          _playerDetailsOverlay.value?.remove();
          _playerDetailsOverlay.value = null;
        }
        _playerDetailsOverlay.value = TrackOptionsButton.showOptions(
          context,
          event.position,
          activeTrack,
        );
      },
      child: Row(
        children: [
          if (activeTrack != null)
            // Scope the pulse glow to ONLY the album art via AnimatedBuilder so
            // the animation doesn't rebuild the whole mini-player (title,
            // artist, image) every frame — that was a major rebuild storm.
            AnimatedBuilder(
              animation: glowController,
              builder: (context, _) {
                final glow = glowController.value;
                return Transform.scale(
                  scale: 1.0 + (0.05 * glow),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    margin: const EdgeInsets.only(right: 6, left: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: playing
                          ? [
                              BoxShadow(
                                color: theme.colorScheme.primary.withValues(
                                  alpha: (0.2 + (0.2 * glow)).toDouble(),
                                ),
                                blurRadius: (10 + (10 * glow)).toDouble(),
                                spreadRadius: (2 + (3 * glow)).toDouble(),
                              )
                            ]
                          : [],
                    ),
                    constraints: const BoxConstraints(
                      maxWidth: 80,
                      maxHeight: 80,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: UniversalImage(
                        path: (track?.album.images).asUrlString(
                            placeholder: ImagePlaceholder.albumArt),
                        placeholder: Assets.images.albumPlaceholder.path,
                      ),
                    ),
                  ),
                );
              },
            ),
          if (mediaQuery.mdAndDown)
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Text(
                    activeTrack?.name ?? "",
                    overflow: TextOverflow.ellipsis,
                    style: theme.typography.normal.copyWith(
                      color: color,
                    ),
                  ),
                  Text(
                    activeTrack?.artists.asString() ?? "",
                    overflow: TextOverflow.ellipsis,
                    style: theme.typography.small.copyWith(color: color),
                  )
                ],
              ),
            ),
          if (mediaQuery.lgAndUp)
            Flexible(
              flex: 1,
              child: Column(
                children: [
                  LinkText(
                    activeTrack?.name ?? "",
                    TrackRoute(trackId: activeTrack?.id ?? ""),
                    push: true,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.bold, color: color),
                  ),
                  ArtistLink(
                    artists: activeTrack?.artists ?? [],
                    onRouteChange: (route) {
                      context.router.navigateNamed(route);
                    },
                    onOverflowArtistClick: () =>
                        context.navigateTo(TrackRoute(trackId: track!.id)),
                  )
                ],
              ),
            ),
        ],
      ),
    );
  }
}
