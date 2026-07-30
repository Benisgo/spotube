import 'package:auto_route/auto_route.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:spotube/collections/side_bar_tiles.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/extensions/constrains.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/modules/root/sidebar/sidebar_footer.dart';

import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/provider/custom_theme/custom_theme_provider.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';

class Sidebar extends HookConsumerWidget {
  final Widget child;

  const Sidebar({
    required this.child,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData(:colorScheme) = Theme.of(context);
    final mediaQuery = MediaQuery.sizeOf(context);

    final layoutMode =
        ref.watch(userPreferencesProvider.select((s) => s.layoutMode));

    final sidebarTileList = useMemoized(
      () => getSidebarTileList(context.l10n),
      [context.l10n],
    );

    final sidebarLibraryTileList = useMemoized(
      () => getSidebarLibraryTileList(context.l10n),
      [context.l10n],
    );

    final tileList = [...sidebarTileList, ...sidebarLibraryTileList];

    final router = context.watchRouter;

    final selectedIndex = tileList.indexWhere(
      (e) => router.currentPath.startsWith(e.pathPrefix),
    );
    final selectedTile = selectedIndex >= 0 ? tileList[selectedIndex] : null;

    if (layoutMode == LayoutMode.compact ||
        (mediaQuery.smAndDown && layoutMode == LayoutMode.adaptive)) {
      return child;
    }

    final primaryButtons = [
      for (final tile in sidebarTileList)
        NavigationItem(
          key: ValueKey(tile.id),
          label: mediaQuery.lgAndUp
              ? Text(
                  tile.title,
                  style: tile.id == selectedTile?.id
                      ? TextStyle(
                          shadows: [
                            Shadow(
                              color: colorScheme.primary.withValues(alpha: 0.5),
                              blurRadius: 10,
                            )
                          ],
                        )
                      : null,
                )
              : null,
          child: Tooltip(
            tooltip: TooltipContainer(child: Text(tile.title)).call,
            child: Icon(
              tile.icon,
              shadows: tile.id == selectedTile?.id
                  ? [
                      Shadow(
                        color: colorScheme.primary.withValues(alpha: 0.8),
                        blurRadius: 12,
                      )
                    ]
                  : null,
            ),
          ),
        ),
    ];

    final libraryButtons = [
      for (final tile in sidebarLibraryTileList)
        NavigationItem(
          key: ValueKey(tile.id),
          label: mediaQuery.lgAndUp
              ? Text(
                  tile.title,
                  style: tile.id == selectedTile?.id
                      ? TextStyle(
                          shadows: [
                            Shadow(
                              color: colorScheme.primary.withValues(alpha: 0.5),
                              blurRadius: 10,
                            )
                          ],
                        )
                      : null,
                )
              : null,
          child: Tooltip(
            tooltip: TooltipContainer(child: Text(tile.title)).call,
            child: Icon(
              tile.icon,
              shadows: tile.id == selectedTile?.id
                  ? [
                      Shadow(
                        color: colorScheme.primary.withValues(alpha: 0.8),
                        blurRadius: 12,
                      )
                    ]
                  : null,
            ),
          ),
        ),
    ];

    final navigationButtons = [
      ...primaryButtons,
      const NavigationDivider(),
      ...libraryButtons,
    ];

    final sidebarHeader = [
      if (mediaQuery.lgAndUp)
        SliverToBoxAdapter(
          child: DefaultTextStyle(
            style: TextStyle(
              fontFamily: "Cookie",
              fontSize: 30,
              letterSpacing: 1.8,
              color: colorScheme.foreground,
            ),
            child: const Text("Spotube"),
          ),
        ),
    ];

    const sidebarFooter = [
      SliverToBoxAdapter(
        child: SidebarFooter(),
      ),
    ];

    final customTheme = ref.watch(customThemeProvider);
    final activeTrack =
        ref.watch(audioPlayerProvider.select((value) => value.activeTrack));
    final hasBackgroundImage = customTheme.enabled &&
        customTheme.useNowPlayingCoverBackground &&
        activeTrack?.album.images.isNotEmpty == true;

    final sidebarWidget = Column(
      children: [
        Expanded(
          child: mediaQuery.lgAndUp
              ? NavigationSidebar(
                  selectedKey:
                      selectedTile != null ? ValueKey(selectedTile.id) : null,
                  header: sidebarHeader,
                  footer: sidebarFooter,
                  onSelected: (key) {
                    if (key case final ValueKey<String> valueKey) {
                      final tile = tileList.firstWhere(
                        (tile) => tile.id == valueKey.value,
                      );
                      context.navigateTo(tile.route);
                    }
                  },
                  children: navigationButtons,
                )
              : NavigationRail(
                  alignment: NavigationRailAlignment.start,
                  selectedKey:
                      selectedTile != null ? ValueKey(selectedTile.id) : null,
                  footer: const [SidebarFooter()],
                  onSelected: (key) {
                    if (key case final ValueKey<String> valueKey) {
                      final tile = tileList.firstWhere(
                        (tile) => tile.id == valueKey.value,
                      );
                      context.navigateTo(tile.route);
                    }
                  },
                  children: navigationButtons,
                ),
        ),
        if (mediaQuery.lgAndUp) const Gap(130) else const Gap(65),
      ],
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        hasBackgroundImage
            ? SurfaceCard(
                surfaceBlur: 20,
                padding: EdgeInsets.zero,
                borderRadius: BorderRadius.zero,
                child: sidebarWidget,
              )
            : sidebarWidget,
        const VerticalDivider(),
        Expanded(child: child),
      ],
    );
  }
}
