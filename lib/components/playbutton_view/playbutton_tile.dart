import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter/shadcn_flutter_extension.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/components/image/universal_image.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/extensions/string.dart';
import 'package:spotube/models/multi_session/multi_session.dart';
import 'package:spotube/provider/multi_session/multi_session.dart';

class PlaybuttonTile extends ConsumerWidget {
  final void Function()? onTap;
  final void Function()? onPlaybuttonPressed;
  final void Function()? onAddToQueuePressed;
  final String? description;

  final String? imageUrl;
  final Widget? image;
  final bool isPlaying;
  final bool isLoading;
  final String title;
  final bool isOwner;
  final bool isPinned;
  final void Function()? onPinPressed;

  const PlaybuttonTile({
    required this.isPlaying,
    required this.isLoading,
    required this.title,
    this.description,
    this.onPlaybuttonPressed,
    this.onAddToQueuePressed,
    this.onPinPressed,
    this.onTap,
    this.isOwner = false,
    this.isPinned = false,
    this.imageUrl,
    this.image,
    super.key,
  }) : assert(
          imageUrl != null || image != null,
          "imageUrl and image can't be null at the same time",
        );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cleanDescription = description?.unescapeHtml().cleanHtml() ?? "";
    final scale = context.theme.scaling;

    final canControlPlayback = ref.watch(
      multiSessionProvider.select(
        (s) => !s.connected || s.can(MultiSessionPermission.controlPlayback),
      ),
    );
    final canEditQueue = ref.watch(
      multiSessionProvider.select(
        (s) => !s.connected || s.can(MultiSessionPermission.editQueue),
      ),
    );

    return Button(
      leading: imageUrl != null
          ? Container(
              width: 50 * scale,
              height: 50 * scale,
              decoration: BoxDecoration(
                borderRadius: context.theme.borderRadiusMd,
                image: DecorationImage(
                  image: UniversalImage.imageProvider(
                    imageUrl!,
                    height: 100 * scale,
                    width: 100 * scale,
                  ),
                  fit: BoxFit.cover,
                ),
              ),
            )
          : SizedBox(
              width: 50 * scale,
              height: 50 * scale,
              child: ClipRRect(
                borderRadius: context.theme.borderRadiusMd,
                child: image,
              ),
            ),
      style: ButtonVariance.ghost.copyWith(
        padding: (context, states, value) {
          return (ButtonVariance.ghost.padding(context, states) as EdgeInsets)
              .copyWith(right: 0, left: 0);
        },
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onPinPressed != null)
            Tooltip(
              tooltip: TooltipContainer(child: Text(isPinned ? "Unpin" : "Pin"))
                  .call,
              child: IconButton.outline(
                icon: Icon(
                  isPinned ? SpotubeIcons.pinOn : SpotubeIcons.pinOff,
                  color: isPinned ? context.theme.colorScheme.primary : null,
                ),
                onPressed: onPinPressed,
              ),
            ),
          if (onPinPressed != null) const Gap(8),
          if (canEditQueue)
            Tooltip(
              tooltip:
                  TooltipContainer(child: Text(context.l10n.add_to_queue)).call,
              child: IconButton.outline(
                icon: const Icon(SpotubeIcons.queueAdd),
                onPressed: onAddToQueuePressed,
                enabled: !isLoading,
              ),
            ),
          if (canEditQueue) const Gap(8),
          if (canControlPlayback)
            Tooltip(
              tooltip: TooltipContainer(child: Text(context.l10n.play)).call,
              child: IconButton.secondary(
                icon: switch ((isLoading, isPlaying)) {
                  (true, _) => const CircularProgressIndicator(size: 22),
                  (false, false) => const Icon(SpotubeIcons.play),
                  (false, true) => const Icon(SpotubeIcons.pause),
                },
                onPressed: onPlaybuttonPressed,
                enabled: !isLoading,
              ),
            ),
        ],
      ),
      enabled: !isLoading,
      onPressed: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title),
          if (cleanDescription.isNotEmpty)
            Text(
              cleanDescription,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ).xSmall().muted(),
        ],
      ),
    );
  }
}
