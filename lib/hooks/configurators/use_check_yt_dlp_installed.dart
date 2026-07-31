import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/modules/settings/youtube_engine_not_installed_dialog.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/youtube_engine/yt_dlp_binary.dart';
import 'package:spotube/services/youtube_engine/yt_dlp_engine.dart';
import 'package:spotube/utils/platform.dart';

void useCheckYtDlpInstalled(WidgetRef ref) {
  // Skip on mobile — Android uses AndroidYtDlpEngine (MethodChannel),
  // iOS doesn't support yt-dlp at all (Bug A1).
  if (kIsMobile) return;
  final context = useContext();

  useEffect(() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final youtubeEngine = ref.read(
        userPreferencesProvider.select(
          (value) => value.youtubeClientEngine,
        ),
      );

      if (youtubeEngine == YoutubeClientEngine.ytDlp &&
          !await YtDlpBinary.ensureAvailable(downloadIfMissing: false) &&
          !await YtDlpEngine.isInstalled() &&
          context.mounted) {
        await showDialog(
          context: context,
          builder: (context) =>
              YouTubeEngineNotInstalledDialog(engine: youtubeEngine),
        );
      }
    });

    return null;
  }, []);
}
