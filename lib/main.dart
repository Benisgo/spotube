import 'dart:async';
import 'dart:ui';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter/services.dart';
import 'package:flutter_discord_rpc/flutter_discord_rpc.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:home_widget/home_widget.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:media_kit/media_kit.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:smtc_windows/smtc_windows.dart';
import 'package:spotube/collections/env.dart';
import 'package:spotube/collections/http-override.dart';
import 'package:spotube/collections/intents.dart';
import 'package:spotube/collections/routes.dart';
import 'package:spotube/hooks/configurators/use_close_behavior.dart';
import 'package:spotube/hooks/configurators/use_deep_linking.dart';
import 'package:spotube/hooks/configurators/use_disable_battery_optimizations.dart';
import 'package:spotube/hooks/configurators/use_fix_window_stretching.dart';
import 'package:spotube/hooks/configurators/use_get_storage_perms.dart';
import 'package:spotube/hooks/configurators/use_has_touch.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/models/theme/app_custom_theme.dart';
import 'package:spotube/modules/settings/color_scheme_picker_dialog.dart';
import 'package:spotube/provider/audio_player/audio_player_streams.dart';
import 'package:spotube/provider/database/database.dart';
import 'package:spotube/provider/custom_theme/custom_theme_provider.dart';
import 'package:spotube/provider/glance/glance.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/provider/metadata_plugin/updater/update_checker.dart';
import 'package:spotube/provider/server/bonsoir.dart';
import 'package:spotube/provider/server/server.dart';
import 'package:spotube/provider/tray_manager/tray_manager.dart';
import 'package:spotube/l10n/l10n.dart';
import 'package:spotube/provider/connect/clients.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/cli/cli.dart';
import 'package:spotube/services/kv_store/encrypted_kv_store.dart';
import 'package:spotube/services/kv_store/kv_store.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/wm_tools/wm_tools.dart';
import 'package:spotube/services/youtube_engine/yt_dlp_binary.dart';
import 'package:spotube/utils/migrations/sandbox.dart';
import 'package:spotube/utils/platform.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:window_manager/window_manager.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:flutter_new_pipe_extractor/flutter_new_pipe_extractor.dart';

ColorScheme _baseColorScheme(ThemeMode mode, SpotubeColor accentMaterialColor) {
  return colorSchemeMap[accentMaterialColor.name]?.call(mode) ??
      switch (mode) {
        ThemeMode.dark => LegacyColorSchemes.darkSlate(),
        _ => LegacyColorSchemes.lightSlate(),
      };
}

ColorScheme _applyCustomColorScheme(
  ColorScheme scheme,
  AppCustomTheme customTheme,
) {
  if (!customTheme.enabled) return scheme;

  final accentColor = customTheme.accentColor;
  return scheme.copyWith(
    background: () => customTheme.backgroundColor,
    foreground: () => customTheme.foregroundColor,
    card: () => customTheme.cardColor,
    cardForeground: () => customTheme.cardForegroundColor,
    popover: () => customTheme.cardColor,
    popoverForeground: () => customTheme.cardForegroundColor,
    primary: () => accentColor,
    primaryForeground: () => customTheme.foregroundColor,
    secondary: () => customTheme.secondaryColor,
    secondaryForeground: () => customTheme.foregroundColor,
    muted: () => customTheme.mutedColor,
    mutedForeground: () => customTheme.mutedForegroundColor,
    accent: () => accentColor,
    accentForeground: () => customTheme.foregroundColor,
    border: () => customTheme.borderColor,
    input: () => customTheme.borderColor,
    ring: () => accentColor.withValues(alpha: 0.55),
    chart1: () => accentColor,
    chart2: () => customTheme.secondaryColor,
    chart3: () => customTheme.borderColor,
    chart4: () => customTheme.mutedForegroundColor,
    chart5: () => customTheme.cardForegroundColor,
  );
}

ThemeData _buildAppTheme(
  ThemeMode mode,
  SpotubeColor accentMaterialColor,
  AppCustomTheme customTheme,
) {
  return ThemeData(
    radius: .5,
    iconTheme: const IconThemeProperties(),
    colorScheme: _applyCustomColorScheme(
      _baseColorScheme(mode, accentMaterialColor),
      customTheme,
    ),
    surfaceOpacity: customTheme.enabled ? customTheme.surfaceOpacity : .8,
    surfaceBlur: customTheme.enabled ? customTheme.surfaceBlur : 10,
  );
}

Future<void> _runStartupStep(
  String label,
  FutureOr<void> Function() action,
) async {
  if (kDebugMode) {
    // ignore: avoid_print
    print('[startup] begin: $label');
  }

  try {
    await Future.sync(action);
  } catch (error, stackTrace) {
    await AppLogger.reportError(
        error, stackTrace, 'Startup step failed: $label');
  } finally {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[startup] end: $label');
    }
  }
}

Future<void> _initializeBackgroundDesktopServices() async {
  await _runStartupStep(
    'yt-dlp configure',
    () => YtDlpBinary.configureExistingBinary(),
  );

  if (kDebugMode) {
    return;
  }

  await _runStartupStep(
    'Discord RPC initialize',
    () => FlutterDiscordRPC.initialize(Env.discordAppId),
  );

  await _runStartupStep(
    'local notifier setup',
    () => localNotifier.setup(appName: 'Spotube'),
  );
}

Future<void> main(List<String> rawArgs) async {
  if (rawArgs.contains("web_view_title_bar")) {
    WidgetsFlutterBinding.ensureInitialized();
    if (runWebViewTitleBarWidget(rawArgs)) {
      return;
    }
  }
  final arguments = await startCLI(rawArgs);
  AppLogger.initialize(arguments["verbose"]);

  AppLogger.runZoned(() async {
    final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();

    HttpOverrides.global = BadCertificateAllowlistOverrides();

    // await registerWindowsScheme("spotify");

    tz.initializeTimeZones();

    FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

    MediaKit.ensureInitialized();

    await _runStartupStep(
      'migrate macOS sandbox',
      () => migrateMacOsFromSandboxToNoSandbox(),
    );

    // force High Refresh Rate on some Android devices (like One Plus)
    if (kIsAndroid) {
      await _runStartupStep(
        'set high refresh rate',
        () => FlutterDisplayMode.setHighRefreshRate(),
      );
    }
    if (kIsAndroid || kIsDesktop) {
      await _runStartupStep(
          'NewPipe extractor init', () => NewPipeExtractor.init());
    }

    if (kIsWindows) {
      await _runStartupStep('SMTC initialize', () => SMTCWindows.initialize());
    }

    if (!kIsWeb) {
      await _runStartupStep(
          'MetadataGod initialize', () => MetadataGod.initialize());
    }

    await _runStartupStep(
        'KV store initialize', () => KVStoreService.initialize());

    if (kIsDesktop) {
      await _runStartupStep(
        'windowManager.setPreventClose',
        () => windowManager.setPreventClose(true),
      );
      await _runStartupStep(
        'WindowManagerTools.initialize',
        () => WindowManagerTools.initialize(),
      );
    }

    await _runStartupStep(
      'encrypted KV store initialize',
      () => EncryptedKvStoreService.initialize(),
    );

    final database = AppDatabase();

    if (kIsIOS) {
      HomeWidget.setAppGroupId("group.spotube_home_player_widget");
    }

    runApp(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) => database),
        ],
        observers: const [
          AppLoggerProviderObserver(),
        ],
        child: const Spotube(),
      ),
    );

    if (kIsDesktop) {
      unawaited(_initializeBackgroundDesktopServices());
    }
  });
}

class Spotube extends HookConsumerWidget {
  const Spotube({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final themeMode =
        ref.watch(userPreferencesProvider.select((s) => s.themeMode));
    final locale = ref.watch(userPreferencesProvider.select((s) => s.locale));
    final accentMaterialColor =
        ref.watch(userPreferencesProvider.select((s) => s.accentColorScheme));
    final customTheme = ref.watch(customThemeProvider);
    final router = useMemoized(() => AppRouter(ref), []);
    final hasTouchSupport = useHasTouch();

    ref.listen(audioPlayerStreamListenersProvider, (_, __) {});
    ref.listen(serverProvider, (_, __) {});
    ref.listen(trayManagerProvider, (_, __) {});

    if (!kDebugMode) {
      ref.listen(bonsoirProvider, (_, __) {});
      ref.listen(connectClientsProvider, (_, __) {});
      ref.listen(metadataPluginsProvider, (_, __) {});
      ref.listen(metadataPluginProvider, (_, __) {});
      ref.listen(audioSourcePluginProvider, (_, __) {});
      ref.listen(metadataPluginUpdateCheckerProvider, (_, __) {});
      ref.listen(audioSourcePluginUpdateCheckerProvider, (_, __) {});
    }

    useFixWindowStretching();
    useDisableBatteryOptimizations();
    useDeepLinking(ref, router);
    useCloseBehavior(ref);
    useGetStoragePermissions(ref);

    useEffect(() {
      FlutterNativeSplash.remove();

      if (kIsMobile) {
        HomeWidget.registerInteractivityCallback(glanceBackgroundCallback);
      }

      return () {
        /// For enabling hot reload for audio player
        if (!kDebugMode) return;
        audioPlayer.dispose();
      };
    }, []);

    return ShadcnApp.router(
      supportedLocales: L10n.all,
      locale: locale.languageCode == "system" ? null : locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: router.config(),
      debugShowCheckedModeBanner: false,
      title: 'Spotube',
      builder: (context, child) {
        child = ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: hasTouchSupport
                ? {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.stylus,
                    PointerDeviceKind.invertedStylus,
                  }
                : null,
          ),
          child: child!,
        );

        if (kIsLinux) {
          child = DragToResizeArea(
            resizeEdgeSize: 2.5,
            child: child,
          );
        }

        return child;
      },
      scaling: const AdaptiveScaling(1),
      theme: _buildAppTheme(
        ThemeMode.light,
        accentMaterialColor,
        customTheme,
      ),
      darkTheme: _buildAppTheme(
        ThemeMode.dark,
        accentMaterialColor,
        customTheme,
      ),
      materialTheme: material.ThemeData(
        brightness: switch (themeMode) {
          ThemeMode.system => MediaQuery.platformBrightnessOf(context),
          ThemeMode.light => Brightness.light,
          ThemeMode.dark => Brightness.dark,
        },
        scaffoldBackgroundColor: _applyCustomColorScheme(
          _baseColorScheme(
            switch (themeMode) {
              ThemeMode.dark => ThemeMode.dark,
              _ => ThemeMode.light,
            },
            accentMaterialColor,
          ),
          customTheme,
        ).background,
        splashFactory: material.NoSplash.splashFactory,
        appBarTheme: const material.AppBarTheme(
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          shadowColor: Colors.transparent,
          elevation: 0,
        ),
      ),
      themeMode: themeMode,
      shortcuts: {
        ...WidgetsApp.defaultShortcuts.map((key, value) {
          return MapEntry(
            LogicalKeySet.fromSet(key.triggers?.toSet() ?? {}),
            value,
          );
        }),
        LogicalKeySet(LogicalKeyboardKey.mediaPlay): const PlayIntent(),
        LogicalKeySet(LogicalKeyboardKey.mediaPause): const PauseIntent(),
        LogicalKeySet(LogicalKeyboardKey.mediaPlayPause): PlayPauseIntent(ref),
        LogicalKeySet(LogicalKeyboardKey.mediaTrackNext):
            const NextTrackIntent(),
        LogicalKeySet(LogicalKeyboardKey.mediaTrackPrevious):
            const PreviousTrackIntent(),
        LogicalKeySet(LogicalKeyboardKey.mediaStop): StopIntent(ref),
        LogicalKeySet(LogicalKeyboardKey.space): PlayPauseIntent(ref),
        LogicalKeySet(LogicalKeyboardKey.comma, LogicalKeyboardKey.control):
            NavigationIntent(router, "/settings"),
        LogicalKeySet(
          LogicalKeyboardKey.digit1,
          LogicalKeyboardKey.control,
          LogicalKeyboardKey.shift,
        ): HomeTabIntent(router, tab: HomeTabs.browse),
        LogicalKeySet(
          LogicalKeyboardKey.digit2,
          LogicalKeyboardKey.control,
          LogicalKeyboardKey.shift,
        ): HomeTabIntent(router, tab: HomeTabs.search),
        LogicalKeySet(
          LogicalKeyboardKey.digit3,
          LogicalKeyboardKey.control,
          LogicalKeyboardKey.shift,
        ): HomeTabIntent(router, tab: HomeTabs.lyrics),
        LogicalKeySet(
          LogicalKeyboardKey.digit4,
          LogicalKeyboardKey.control,
          LogicalKeyboardKey.shift,
        ): HomeTabIntent(router, tab: HomeTabs.userPlaylists),
        LogicalKeySet(
          LogicalKeyboardKey.digit5,
          LogicalKeyboardKey.control,
          LogicalKeyboardKey.shift,
        ): HomeTabIntent(router, tab: HomeTabs.userArtists),
        LogicalKeySet(
          LogicalKeyboardKey.digit6,
          LogicalKeyboardKey.control,
          LogicalKeyboardKey.shift,
        ): HomeTabIntent(router, tab: HomeTabs.userAlbums),
        LogicalKeySet(
          LogicalKeyboardKey.digit7,
          LogicalKeyboardKey.control,
          LogicalKeyboardKey.shift,
        ): HomeTabIntent(router, tab: HomeTabs.userLocalLibrary),
        LogicalKeySet(
          LogicalKeyboardKey.digit8,
          LogicalKeyboardKey.control,
          LogicalKeyboardKey.shift,
        ): HomeTabIntent(router, tab: HomeTabs.userDownloads),
        LogicalKeySet(
          LogicalKeyboardKey.keyW,
          LogicalKeyboardKey.control,
          LogicalKeyboardKey.shift,
        ): CloseAppIntent(),
      },
      actions: {
        ...WidgetsApp.defaultActions,
        PlayIntent: PlayAction(),
        PauseIntent: PauseAction(),
        PlayPauseIntent: PlayPauseAction(),
        NextTrackIntent: NextTrackAction(),
        PreviousTrackIntent: PreviousTrackAction(),
        StopIntent: StopAction(),
        NavigationIntent: NavigationAction(),
        HomeTabIntent: HomeTabAction(),
        CloseAppIntent: CloseAppAction(),
      },
    );
  }
}
