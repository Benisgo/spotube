import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart' show Badge;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/components/ui/count_badge.dart';
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/extensions/constrains.dart';
import 'package:spotube/provider/multi_session/multi_session.dart';

/// Entry-point button for Multi-Session listening rooms, mirroring the
/// "Devices" button. When the user is in a room it shows the live room status:
/// a connected indicator and the current member count. Tapping it opens the
/// multi-session room page.
class MultiSessionButton extends HookConsumerWidget {
  final bool _sidebar;
  const MultiSessionButton({super.key}) : _sidebar = false;
  const MultiSessionButton.sidebar({super.key}) : _sidebar = true;

  @override
  Widget build(BuildContext context, ref) {
    final session = ref.watch(multiSessionProvider);

    final inRoom = session.connected && session.code != null;
    final memberCount = session.snapshot?.members.length;
    final countLabel = (inRoom && memberCount != null && memberCount > 0)
        ? memberCount.toString()
        : null;

    void open() {
      context.navigateTo(const MultiSessionRoute());
    }

    final label = inRoom
        ? "Room ${session.code}"
        : session.connecting
            ? "Connecting…"
            : "Multi-Session";

    if (_sidebar) {
      final mediaQuery = MediaQuery.sizeOf(context);
      if (mediaQuery.mdAndDown) {
        // Mirror the Downloads button: wrap the IconButton in the material
        // Badge (not the reverse), so the count badge positions and sizes the
        // same way as the other sidebar buttons.
        return Tooltip(
          tooltip: TooltipContainer(
            child: Text(inRoom ? "Room ${session.code}" : "Multi-Session"),
          ).call,
          child: Badge(
            isLabelVisible: inRoom,
            label: Text(countLabel ?? ""),
            child: IconButton.ghost(
              icon: const Icon(SpotubeIcons.groups),
              onPressed: open,
            ),
          ),
        );
      }

      return SizedBox(
        width: double.infinity,
        child: Button(
          style: inRoom ? ButtonVariance.secondary : ButtonVariance.outline,
          onPressed: open,
          leading: const Icon(SpotubeIcons.groups),
          trailing: countLabel != null ? CountBadge(countLabel) : null,
          child: Text(label),
        ),
      );
    }

    return SecondaryBadge(
      onPressed: open,
      style: const ButtonStyle.secondary(size: ButtonSize(.8)),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(SpotubeIcons.groups, size: 16),
          if (inRoom)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: DotItem(size: 6, borderRadius: 10, color: Colors.green),
            ),
        ],
      ),
      trailing: countLabel == null ? null : Text("($countLabel)"),
      child: Text(label),
    );
  }
}
