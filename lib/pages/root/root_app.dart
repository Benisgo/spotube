import 'package:auto_route/auto_route.dart';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter/shadcn_flutter_extension.dart';
import 'package:spotube/components/image/universal_image.dart';
import 'package:spotube/hooks/configurators/use_check_yt_dlp_installed.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/modules/root/bottom_player.dart';
import 'package:spotube/modules/root/sidebar/sidebar.dart';
import 'package:spotube/modules/root/spotube_navigation_bar.dart';
import 'package:spotube/hooks/configurators/use_endless_playback.dart';
import 'package:spotube/modules/root/use_global_subscriptions.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/custom_theme/custom_theme_provider.dart';
import 'package:spotube/provider/glance/glance.dart';

@RoutePage()
class RootAppPage extends HookConsumerWidget {
  const RootAppPage({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final backgroundColor = Theme.of(context).colorScheme.background;
    final brightness = Theme.of(context).brightness;
    final customTheme = ref.watch(customThemeProvider);
    final activeTrack =
        ref.watch(audioPlayerProvider.select((value) => value.activeTrack));
    final backgroundImage = customTheme.enabled &&
            customTheme.useNowPlayingCoverBackground &&
            activeTrack?.album.images.isNotEmpty == true
        ? activeTrack!.album.images.asUrlString(
            index: activeTrack.album.images.length - 1,
            placeholder: ImagePlaceholder.albumArt,
          )
        : null;

    ref.listen(glanceProvider, (_, __) {});

    useGlobalSubscriptions(ref);
    useEndlessPlayback(ref);
    useCheckYtDlpInstalled(ref);

    useEffect(() {
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          statusBarColor: backgroundColor, // status bar color
          statusBarIconBrightness: brightness == Brightness.dark
              ? Brightness.light
              : Brightness.dark,
        ),
      );
      return null;
    }, [backgroundColor, brightness]);

    final scaffold = MediaQuery.removeViewInsets(
      context: context,
      removeBottom: true,
      child: SafeArea(
        top: false,
        child: Scaffold(
          backgroundColor: backgroundImage != null ? Colors.transparent : null,
          footers: const [
            BottomPlayer(),
            SpotubeNavigationBar(),
          ],
          floatingFooter: true,
          child: Sidebar(
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: MediaQuery.paddingOf(context)
                    .copyWith(bottom: 100 * context.theme.scaling),
              ),
              child: Theme(
                data: Theme.of(context).copyWith(
                  colorScheme: () => Theme.of(context).colorScheme.copyWith(
                    background: backgroundImage != null
                        ? () => Colors.transparent
                        : null,
                  ),
                ),
                child: const AutoRouter(),
              ),
            ),
          ),
        ),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: backgroundColor),
        if (backgroundImage != null)
          Stack(
            fit: StackFit.expand,
            children: [
              Opacity(
                opacity: customTheme.backgroundImageOpacity,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(
                    sigmaX: customTheme.backgroundImageBlur,
                    sigmaY: customTheme.backgroundImageBlur,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      image: DecorationImage(
                        image: UniversalImage.imageProvider(backgroundImage),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      backgroundColor.withValues(alpha: 0.5),
                      backgroundColor.withValues(alpha: 0.85),
                    ],
                  ),
                ),
              ),
            ],
          ),
        scaffold,
      ],
    );
  }
}
