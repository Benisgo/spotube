import 'dart:async';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/hooks/configurators/use_window_listener.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/provider/multi_session/multi_session.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/audio_player/audio_player.dart';

import 'package:local_notifier/local_notifier.dart';
import 'package:spotube/utils/platform.dart';
import 'package:window_manager/window_manager.dart';

final closeNotification = !kIsDesktop
    ? null
    : (LocalNotification(
        title: 'Spotube',
        body: 'Running in background. Minimized to System Tray',
        actions: [
          LocalNotificationAction(text: 'Close The App'),
        ],
      )..onClickAction = (value) {
        exit(0);
      });

void useCloseBehavior(WidgetRef ref) {
  Future<void> closeApp() async {
    // Fire-and-forget multi-session cleanup (don't block close on it)
    unawaited(ref
        .read(multiSessionProvider.notifier)
        .shutdownForAppClose()
        .timeout(const Duration(seconds: 1), onTimeout: () {})
        .catchError((_) {}));

    if (kIsDesktop) {
      // Abort the active stream so libmpv doesn't block process teardown for
      // 3-5s. Best-effort: the shared helper is idempotent and bounded, so the
      // window-X, notification, tray, keyboard-shortcut, and sleep-timer close
      // paths can all call it without double-disposing the singleton.
      await disposeAudioPlayerForClose();
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
      return;
    }

    exit(0);
  }

  if (closeNotification != null) {
    closeNotification!.onClickAction = (value) {
      unawaited(closeApp());
    };
  }

  useWindowListener(
    onWindowClose: () {
      final preferences = ref.read(userPreferencesProvider);
      if (preferences.closeBehavior == CloseBehavior.minimizeToTray) {
        unawaited(windowManager.hide());
        closeNotification?.show();
      } else {
        unawaited(closeApp());
      }
    },
  );
}
