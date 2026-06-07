import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/theme/app_custom_theme.dart';
import 'package:spotube/services/kv_store/kv_store.dart';

class CustomThemeNotifier extends Notifier<AppCustomTheme> {
  @override
  AppCustomTheme build() => KVStoreService.customTheme;

  Future<void> setTheme(AppCustomTheme theme) async {
    state = theme;
    await KVStoreService.setCustomTheme(theme);
  }

  Future<void> reset() async {
    await setTheme(AppCustomTheme.defaults());
  }
}

final customThemeProvider =
    NotifierProvider<CustomThemeNotifier, AppCustomTheme>(
  () => CustomThemeNotifier(),
);
