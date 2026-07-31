import 'package:auto_route/auto_route.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/components/ui/count_badge.dart';
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/extensions/constrains.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/provider/connect/clients.dart';

class ConnectDeviceButton extends HookConsumerWidget {
  final bool _sidebar;
  const ConnectDeviceButton({super.key}) : _sidebar = false;
  const ConnectDeviceButton.sidebar({super.key}) : _sidebar = true;

  @override
  Widget build(BuildContext context, ref) {
    final connectClients = ref.watch(connectClientsProvider);

    final hasServices =
        connectClients.asData?.value.services.isNotEmpty == true;

    if (_sidebar) {
      final mediaQuery = MediaQuery.sizeOf(context);

      if (mediaQuery.mdAndDown) {
        return Tooltip(
          tooltip: TooltipContainer(child: Text(context.l10n.devices)).call,
          child: IconButton.ghost(
            icon: const Icon(SpotubeIcons.speaker),
            onPressed: () {
              context.navigateTo(const ConnectRoute());
            },
          ),
        );
      }

      // Highlight the Devices button while on the Connect page, matching the
      // Downloads button's active state in the sidebar footer.
      final isOnConnectRoute =
          context.watchRouter.currentPath.startsWith("/connect");

      return SizedBox(
        width: double.infinity,
        child: Button(
          style: isOnConnectRoute
              ? ButtonVariance.secondary
              : ButtonVariance.outline,
          onPressed: () {
            context.navigateTo(const ConnectRoute());
          },
          // Icon on the LEFT to match the Downloads / Multi-Session buttons.
          leading: const Icon(SpotubeIcons.speaker),
          trailing: hasServices
              ? CountBadge("${connectClients.asData?.value.services.length}")
              : null,
          child: Text(context.l10n.devices),
        ),
      );
    }

    return SecondaryBadge(
      onPressed: () {
        context.navigateTo(const ConnectRoute());
      },
      style: const ButtonStyle.secondary(size: ButtonSize(.8)),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(SpotubeIcons.speaker, size: 16),
          if (connectClients.asData?.value.resolvedService != null)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: DotItem(
                size: 6,
                borderRadius: 10,
                color: Colors.green,
              ),
            ),
        ],
      ),
      trailing: hasServices
          ? Text("(${connectClients.asData?.value.services.length})")
          : null,
      child: Text(context.l10n.devices),
    );
  }
}
