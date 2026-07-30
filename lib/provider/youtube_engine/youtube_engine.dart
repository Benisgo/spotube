import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/youtube_engine/android_yt_dlp_engine.dart';
import 'package:spotube/services/youtube_engine/innertube_engine.dart';
import 'package:spotube/services/youtube_engine/newpipe_engine.dart';
import 'package:spotube/services/youtube_engine/youtube_explode_engine.dart';
import 'package:spotube/services/youtube_engine/yt_music_engine.dart';
import 'package:spotube/services/youtube_engine/yt_dlp_engine.dart';
import 'package:spotube/services/youtube_engine/fallback_youtube_engine.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';

final youtubeEngineProvider = Provider<YouTubeEngine>((ref) {
  final enginesList = ref.watch(
    userPreferencesProvider.select((value) => value.youtubeClientEngines),
  );

  List<YouTubeEngine> instances = [];

  for (final engine in enginesList) {
    if (engine == YoutubeClientEngine.innerTube &&
        InnerTubeEngine.isAvailableForPlatform) {
      instances.add(InnerTubeEngine());
    } else if (engine == YoutubeClientEngine.newPipe &&
        NewPipeEngine.isAvailableForPlatform) {
      instances.add(NewPipeEngine());
    } else if (engine == YoutubeClientEngine.ytDlp &&
        YtDlpEngine.isAvailableForPlatform) {
      instances.add(YtDlpEngine());
    } else if (engine == YoutubeClientEngine.ytDlp &&
        AndroidYtDlpEngine.isAvailableForPlatform) {
      instances.add(AndroidYtDlpEngine());
    } else if (engine == YoutubeClientEngine.youtubeExplode &&
        YouTubeExplodeEngine.isAvailableForPlatform) {
      instances.add(YouTubeExplodeEngine());
    } else if (engine == YoutubeClientEngine.youtubeMusic &&
        YtMusicEngine.isAvailableForPlatform) {
      instances.add(YtMusicEngine());
    }
  }

  if (instances.isEmpty) {
    instances.add(YouTubeExplodeEngine());
  }

  return FallbackYouTubeEngine(instances);
});
