import 'dart:async';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/hooks/configurators/use_window_listener.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/provider/multi_session/multi_session.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';

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
    await Future.any([
      ref.read(multiSessionProvider.notifier).shutdownForAppClose(),
      Future<void>.delayed(const Duration(milliseconds: 150)),
    ]);
    exit(0);
  }

  if (closeNotification != null) {
    closeNotification!.onClickAction = (value) {
      unawaited(closeApp());
    };
  }

  useWindowListener(
    onWindowClose: () async {
      final preferences = ref.read(userPreferencesProvider);
      if (preferences.closeBehavior == CloseBehavior.minimizeToTray) {
        await windowManager.hide();
        closeNotification?.show();
      } else {
        await closeApp();
      }
    },
  );
}
