import 'package:auto_route/auto_route.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/components/fallbacks/not_found.dart';
import 'package:spotube/components/image/universal_image.dart';
import 'package:spotube/components/inter_scrollbar/inter_scrollbar.dart';
import 'package:spotube/components/ui/button_tile.dart';
import 'package:spotube/extensions/constrains.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/extensions/duration.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/server/sourced_track_provider.dart';
import 'package:spotube/collections/spotube_icons.dart';

class SiblingTracksSheet extends HookConsumerWidget {
  final bool floating;
  const SiblingTracksSheet({
    super.key,
    this.floating = true,
  });

  @override
  Widget build(BuildContext context, ref) {
    final controller = useScrollController();
    final searchController = useTextEditingController();

    final activeTrack =
        ref.watch(audioPlayerProvider.select((e) => e.activeTrack));

    if (activeTrack == null || activeTrack is! SpotubeFullTrackObject) {
      return const SafeArea(child: NotFound());
    }

    return HookBuilder(builder: (context) {
      final sourcedTrack = ref.watch(sourcedTrackProvider(activeTrack));
      final sourcedTrackNotifier =
          ref.watch(sourcedTrackProvider(activeTrack).notifier);
      final searchQuery = useState("");

      final siblings = useMemoized<List<SpotubeAudioSourceMatchObject>>(
        () => !sourcedTrack.isLoading
            ? <SpotubeAudioSourceMatchObject>[
                if (sourcedTrack.asData?.value != null)
                  sourcedTrack.asData!.value.info,
                ...?sourcedTrack.asData?.value.siblings,
              ]
            : <SpotubeAudioSourceMatchObject>[],
        [sourcedTrack],
      );
      final filteredSiblings = useMemoized(
        () {
          final query = searchQuery.value.trim().toLowerCase();
          if (query.isEmpty) return siblings;

          return siblings.where((sourceInfo) {
            final haystack =
                "${sourceInfo.title} ${sourceInfo.artists.join(" ")}"
                    .toLowerCase();
            return haystack.contains(query);
          }).toList();
        },
        [siblings, searchQuery.value],
      );

      useEffect(() {
        /// Populate sibling when active track changes
        if (sourcedTrack.asData?.value != null &&
            sourcedTrack.asData?.value.siblings.isEmpty == true) {
          sourcedTrackNotifier.copyWithSibling();
        }
        return null;
      }, [sourcedTrack]);

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8.0, vertical: 16),
              child: Row(
                spacing: 5,
                children: [
                  Expanded(
                    child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: Text(
                          context.l10n.alternative_track_sources,
                        ).bold()),
                  ),
                  if (!floating)
                    IconButton.ghost(
                      icon: const Icon(SpotubeIcons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextField(
                controller: searchController,
                enabled: !sourcedTrack.isLoading,
                onChanged: (value) => searchQuery.value = value,
                placeholder: Text(context.l10n.search),
                features: const [
                  InputFeature.leading(Icon(SpotubeIcons.search)),
                ],
              ),
            ),
            const Gap(8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: sourcedTrack.isLoading
                  ? const SizedBox(
                      width: double.infinity,
                      child: LinearProgressIndicator(),
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: InterScrollbar(
                  controller: controller,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(8.0),
                    controller: controller,
                    itemCount: filteredSiblings.length,
                    separatorBuilder: (context, index) => const Gap(8),
                    itemBuilder: (context, index) {
                      final sourceInfo = filteredSiblings[index];

                      return ButtonTile(
                        style: ButtonVariance.ghost,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        title: Text(
                          sourceInfo.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        leading: sourceInfo.thumbnail != null
                            ? UniversalImage(
                                path: sourceInfo.thumbnail!,
                                height: 60,
                                width: 60,
                              )
                            : null,
                        trailing:
                            Text(sourceInfo.duration.toHumanReadableString()),
                        subtitle: Text(
                          sourceInfo.artists.join(", "),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        enabled: !sourcedTrack.isLoading,
                        selected: !sourcedTrack.isLoading &&
                            sourceInfo.id == sourcedTrack.asData?.value.info.id,
                        onPressed: () async {
                          if (!sourcedTrack.isLoading &&
                              sourceInfo.id !=
                                  sourcedTrack.asData?.value.info.id) {
                            final swapped = await sourcedTrackNotifier
                                .swapWithSibling(sourceInfo);
                            if (swapped.info.id == sourceInfo.id) {
                              await ref
                                  .read(audioPlayerProvider.notifier)
                                  .swapActiveSource();
                            }

                            if (context.mounted) {
                              if (MediaQuery.sizeOf(context).mdAndUp) {
                                closeOverlay(context);
                              } else if (floating) {
                                closeDrawer(context);
                              } else {
                                context.router.maybePop();
                              }
                            }
                          }
                        },
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}
