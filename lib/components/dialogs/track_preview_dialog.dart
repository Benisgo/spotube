import 'dart:async';

import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/components/image/universal_image.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/models/multi_session/multi_session.dart';
import 'package:spotube/provider/multi_session/multi_session.dart';
import 'package:spotube/provider/server/sourced_track_provider.dart';
import 'package:spotube/services/audio_player/custom_player.dart';

class TrackPreviewDialog extends HookConsumerWidget {
  final SpotubeTrackObject track;

  const TrackPreviewDialog({super.key, required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = useMemoized(() => CustomPlayer());
    final isPlaying = useState(false);
    final duration = useState(Duration.zero);
    final position = useState(Duration.zero);
    final hasError = useState(false);
    final isBuffering = useState(true);
    final previewLimit = useMemoized(() => const Duration(seconds: 30));

    final multiSession = ref.watch(multiSessionProvider);
    final canSuggestTracks = track is SpotubeFullTrackObject &&
        multiSession.connected &&
        (multiSession.snapshot?.communityQueueEnabled ?? false) &&
        multiSession.can(MultiSessionPermission.suggestTracks);
    final sourcedTrackProviderRef = track is SpotubeFullTrackObject
        ? sourcedTrackProvider(track as SpotubeFullTrackObject)
        : null;
    final sourcedTrack = sourcedTrackProviderRef != null
        ? ref.watch(sourcedTrackProviderRef)
        : null;
    final sourcedTrackNotifier = sourcedTrackProviderRef != null
        ? ref.read(sourcedTrackProviderRef.notifier)
        : null;

    useEffect(() {
      final subscriptions = [
        player.stream.playing.listen((value) {
          isPlaying.value = value;
        }),
        player.stream.duration.listen((value) {
          duration.value = value;
        }),
        player.stream.position.listen((value) {
          position.value = value;
          if (value >= previewLimit) {
            player.pause();
            player.seek(Duration.zero);
          }
        }),
        player.stream.error.listen((_) {
          hasError.value = true;
          isBuffering.value = false;
        }),
        player.stream.buffering.listen((value) {
          isBuffering.value = value;
        }),
      ];

      return () {
        for (final subscription in subscriptions) {
          unawaited(subscription.cancel());
        }
        unawaited(player.stop());
        unawaited(player.dispose());
      };
    }, [player, previewLimit]);

    useEffect(() {
      unawaited(
          ref.read(multiSessionProvider.notifier).setPreviewSilenced(true));
      return () {
        unawaited(
          ref.read(multiSessionProvider.notifier).setPreviewSilenced(false),
        );
      };
    }, const []);

    useEffect(() {
      final url = sourcedTrack?.valueOrNull?.url;
      if (url == null || url.isEmpty) return null;

      Future<void>(() async {
        hasError.value = false;
        isBuffering.value = true;
        await player.open(Media(url), play: false);
        await player.seek(Duration.zero);
      });

      return null;
    }, [player, sourcedTrack?.valueOrNull?.url]);

    useEffect(() {
      if (sourcedTrack?.valueOrNull != null &&
          sourcedTrack!.valueOrNull!.siblings.isEmpty) {
        unawaited(sourcedTrackNotifier?.copyWithSibling() ?? Future.value());
      }
      return null;
    }, [sourcedTrack?.valueOrNull?.info.id]);

    final maxDuration = duration.value == Duration.zero
        ? previewLimit
        : duration.value < previewLimit
            ? duration.value
            : previewLimit;
    final safePosition =
        position.value > maxDuration ? maxDuration : position.value;
    final sourceChoices = sourcedTrack?.valueOrNull == null
        ? const <SpotubeAudioSourceMatchObject>[]
        : [
            sourcedTrack!.valueOrNull!.info,
            ...sourcedTrack.valueOrNull!.siblings,
          ];
    final selectedSourceId = sourcedTrack?.valueOrNull?.info.id;

    return AlertDialog(
      title: const Text('Track preview'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: [
            Row(
              spacing: 12,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: UniversalImage(
                    path:
                        track.album.images.smallest(ImagePlaceholder.albumArt),
                    width: 72,
                    height: 72,
                    fit: BoxFit.cover,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 4,
                    children: [
                      Text(
                        track.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        track.artists.map((e) => e.name).join(', '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ).small().muted(),
                    ],
                  ),
                ),
              ],
            ),
            if (track is! SpotubeFullTrackObject)
              const Text('Preview is unavailable for this track.')
            else if (sourcedTrack == null || sourcedTrack.isLoading)
              const Center(child: CircularProgressIndicator())
            else if (hasError.value || sourcedTrack.hasError)
              const Text('Unable to load a preview for this track.')
            else ...[
              if (sourceChoices.isNotEmpty)
                Select<String>(
                  value: selectedSourceId,
                  placeholder: const Text('Track source'),
                  itemBuilder: (context, value) {
                    final item = sourceChoices.firstWhere(
                      (source) => source.id == value,
                    );
                    return Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    );
                  },
                  onChanged: (value) async {
                    if (value == null || value == selectedSourceId) return;
                    final choice = sourceChoices.firstWhere(
                      (source) => source.id == value,
                    );
                    await sourcedTrackNotifier?.swapWithSibling(choice);
                  },
                  popup: SelectPopup.builder(
                    searchPlaceholder: const Text('Search sources'),
                    builder: (context, searchQuery) {
                      final filtered =
                          searchQuery == null || searchQuery.isEmpty
                              ? sourceChoices
                              : sourceChoices.where((source) {
                                  final haystack =
                                      "${source.title} ${source.artists.join(" ")}"
                                          .toLowerCase();
                                  return haystack.contains(
                                    searchQuery.toLowerCase(),
                                  );
                                }).toList();
                      return SelectItemBuilder(
                        childCount: filtered.length,
                        builder: (context, index) {
                          final item = filtered[index];
                          return SelectItemButton(
                            value: item.id,
                            child: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        },
                      );
                    },
                  ).call,
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton.secondary(
                    icon: Icon(
                      isPlaying.value ? SpotubeIcons.pause : SpotubeIcons.play,
                    ),
                    onPressed: () async {
                      if (isPlaying.value) {
                        await player.pause();
                        return;
                      }

                      if (safePosition >= maxDuration) {
                        await player.seek(Duration.zero);
                      }
                      await player.play();
                    },
                  ),
                ],
              ),
              Slider(
                value: SliderValue.single(
                  safePosition.inMilliseconds /
                      maxDuration.inMilliseconds.clamp(1, 30000),
                ),
                enabled: !isBuffering.value,
                onChanged: (value) async {
                  await player.seek(
                    Duration(
                      milliseconds:
                          (value.value * maxDuration.inMilliseconds).round(),
                    ),
                  );
                },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('${safePosition.inSeconds}s').small().muted(),
                  Text('${maxDuration.inSeconds}s preview').small().muted(),
                ],
              ),
              if (isBuffering.value)
                const Center(
                  child: CircularProgressIndicator(size: 18),
                ),
            ],
          ],
        ),
      ),
      actions: [
        Button.secondary(
          onPressed: () async {
            await player.pause();
            if (context.mounted) {
              Navigator.of(context).pop();
            }
          },
          child: const Text('Close'),
        ),
        if (canSuggestTracks)
          Button.primary(
            onPressed: () {
              ref
                  .read(multiSessionProvider.notifier)
                  .suggestTrack(track as SpotubeFullTrackObject);
              Navigator.of(context).pop();
              showToast(
                context: context,
                builder: (context, overlay) => SurfaceCard(
                  child: const Text('Track suggested!').small(),
                ),
              );
            },
            child: const Text('Suggest Track'),
          ),
      ],
    );
  }
}
