import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/components/titlebar/titlebar.dart';
import 'package:spotube/extensions/constrains.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/modules/connect/connect_device.dart';
import 'package:spotube/modules/stats/summary/summary.dart';
import 'package:spotube/modules/stats/top/top.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/utils/platform.dart';
import 'package:auto_route/auto_route.dart';

@RoutePage()
class StatsPage extends HookConsumerWidget {
  static const name = "stats";

  const StatsPage({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final mediaQuery = MediaQuery.of(context);
    final layoutMode =
        ref.watch(userPreferencesProvider.select((s) => s.layoutMode));

    final showMobileHeader = layoutMode == LayoutMode.compact ||
        (mediaQuery.smAndDown && layoutMode == LayoutMode.adaptive);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        context.navigateTo(const HomeRoute());
      },
      child: SafeArea(
        bottom: false,
        child: Scaffold(
          headers: [
            if (kTitlebarVisible && !showMobileHeader)
              const TitleBar(automaticallyImplyLeading: false),
            if (showMobileHeader)
              TitleBar(
                showWindowButtons: false,
                automaticallyImplyLeading: false,
                title: Text(context.l10n.stats, textAlign: TextAlign.center),
                trailing: [
                  const ConnectDeviceButton(),
                  const Gap(8),
                  IconButton.ghost(
                    icon: const Icon(SpotubeIcons.settings, size: 20),
                    onPressed: () =>
                        context.navigateTo(const SettingsRoute()),
                  ),
                  const Gap(8),
                ],
              ),
          ],
          child: CustomScrollView(
            slivers: [
              if (kIsMacOS) const SliverGap(20),
              const StatsPageSummarySection(),
              const StatsPageTopSection(),
              const SliverToBoxAdapter(
                child: SafeArea(
                  child: SizedBox(),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}
