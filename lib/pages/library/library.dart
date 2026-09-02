import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart' show Badge, WidgetsBinding;
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/collections/side_bar_tiles.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/components/titlebar/titlebar.dart';
import 'package:spotube/extensions/constrains.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/modules/connect/connect_device.dart';
import 'package:spotube/modules/connect/multi_session_button.dart';
import 'package:spotube/pages/library/user_albums.dart';
import 'package:spotube/pages/library/user_artists.dart';
import 'package:spotube/pages/library/user_downloads.dart';
import 'package:spotube/pages/library/user_local_tracks/user_local_tracks.dart';
import 'package:spotube/pages/library/user_playlists.dart';
import 'package:spotube/provider/download_manager_provider.dart';

@RoutePage()
class LibraryPage extends HookConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final downloadingCount = ref.watch(
      downloadManagerProvider.select(
        (tasks) => tasks
            .where((e) =>
                e.status == DownloadStatus.downloading ||
                e.status == DownloadStatus.queued)
            .length,
      ),
    );
    final router = context.router;
    final sidebarLibraryTileList = useMemoized(
      () => [
        ...getSidebarLibraryTileList(context.l10n),
        SideBarTiles(
          id: "downloads",
          pathPrefix: "/library/downloads",
          title: context.l10n.downloads,
          route: const UserDownloadsRoute(),
          icon: SpotubeIcons.download,
        ),
      ],
      [context.l10n],
    );
    final currentIndex = sidebarLibraryTileList.indexWhere(
      (e) => router.currentPath.startsWith(e.pathPrefix),
    );

    final pageController = usePageController(
      initialPage: currentIndex >= 0 ? currentIndex : 0,
    );
    final isAnimating = useRef(false);
    final isFirstFrame = useRef(true);

    // Jump PageView to the correct page when route changes (e.g. from sidebar).
    // Use jumpToPage instead of animateToPage to avoid triggering
    // onPageChanged callbacks that cause navigation loops.
    useEffect(() {
      if (currentIndex < 0) return null;
      if (isFirstFrame.value) {
        isFirstFrame.value = false;
        return null;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (pageController.hasClients) {
          pageController.jumpToPage(currentIndex);
        }
      });
      return null;
    }, [currentIndex]);

    final pages = useMemoized(
      () => const [
        UserPlaylistsPage(),
        UserArtistsPage(),
        UserAlbumsPage(),
        UserLocalLibraryPage(),
        UserDownloadsPage(),
      ],
      [],
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        context.navigateTo(const HomeRoute());
      },
      child: SafeArea(
        bottom: false,
        child: LayoutBuilder(builder: (context, constraints) {
          return Scaffold(
            headers: [
              if (constraints.smAndDown)
                TitleBar(
                  showWindowButtons: false,
                  automaticallyImplyLeading: false,
                  trailing: [
                    const ConnectDeviceButton.sidebar(),
                    const MultiSessionButton.sidebar(),
                    const Gap(8),
                    IconButton.ghost(
                      icon: const Icon(SpotubeIcons.settings, size: 20),
                      onPressed: () =>
                          context.navigateTo(const SettingsRoute()),
                    ),
                    const Gap(8),
                  ],
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: TabList(
                      index: currentIndex >= 0 ? currentIndex : 0,
                      onChanged: (index) {
                        isAnimating.value = true;
                        pageController
                            .animateToPage(
                              index,
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeInOut,
                            )
                            .then((_) => isAnimating.value = false);
                        context.navigateTo(
                          sidebarLibraryTileList[index].route,
                        );
                      },
                      children: [
                        for (final tile in sidebarLibraryTileList)
                          TabItem(
                            child: Badge(
                              isLabelVisible: tile.id == 'downloads' &&
                                  downloadingCount > 0,
                              label: Text(downloadingCount.toString()),
                              child: Text(tile.title),
                            ),
                          ),
                      ],
                    ),
                  ),
                )
              else
                const TitleBar(
                  automaticallyImplyLeading: false,
                  backgroundColor: Colors.transparent,
                  surfaceBlur: 0,
                  height: 32,
                ),
              const Gap(10),
            ],
            child: PageView(
              controller: pageController,
              onPageChanged: (index) {
                if (index >= 0 && index < sidebarLibraryTileList.length) {
                  // Only push the route if the user is swiping.
                  // If TabList is animating the pageController, we skip this.
                  if (!isAnimating.value) {
                    context.navigateTo(sidebarLibraryTileList[index].route);
                  }
                }
              },
              children: pages,
            ),
          );
        }),
      ),
    );
  }
}
