import 'dart:async';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class FallbackYouTubeEngine implements YouTubeEngine {
  final List<YouTubeEngine> engines;
  
  // A global stream that UI can listen to for toast notifications
  static final StreamController<String> fallbackNotifier = StreamController<String>.broadcast();

  FallbackYouTubeEngine(this.engines) {
    if (engines.isEmpty) {
      throw ArgumentError('FallbackYouTubeEngine requires at least one engine');
    }
  }

  static bool get isAvailableForPlatform => true;

  static Future<bool> isInstalled() async => true;

  @override
  Future<Video> getVideo(String videoId) async {
    for (int i = 0; i < engines.length; i++) {
      try {
        return await engines[i].getVideo(videoId);
      } catch (e, stack) {
        if (i == engines.length - 1) rethrow;
        AppLogger.reportError(e, stack);
        fallbackNotifier.add('Engine failed. Falling back to next...');
      }
    }
    throw Exception('All engines failed');
  }

  @override
  Future<StreamManifest> getStreamManifest(String videoId) async {
    for (int i = 0; i < engines.length; i++) {
      try {
        return await engines[i].getStreamManifest(videoId);
      } catch (e, stack) {
        if (i == engines.length - 1) rethrow;
        AppLogger.reportError(e, stack);
        fallbackNotifier.add('Stream failed. Falling back to next engine...');
      }
    }
    throw Exception('All engines failed');
  }

  @override
  Future<(Video, StreamManifest)> getVideoWithStreamInfo(String videoId) async {
    for (int i = 0; i < engines.length; i++) {
      try {
        return await engines[i].getVideoWithStreamInfo(videoId);
      } catch (e, stack) {
        if (i == engines.length - 1) rethrow;
        AppLogger.reportError(e, stack);
        fallbackNotifier.add('Engine failed. Falling back to next...');
      }
    }
    throw Exception('All engines failed');
  }

  @override
  Future<List<Video>> searchVideos(String query) async {
    for (int i = 0; i < engines.length; i++) {
      try {
        final results = await engines[i].searchVideos(query);
        if (results.isNotEmpty) return results;
      } catch (e, stack) {
        AppLogger.reportError(e, stack);
      }
      
      if (i < engines.length - 1) {
        fallbackNotifier.add('Search failed. Trying next engine...');
      }
    }
    return [];
  }

  @override
  void dispose() {
    for (final engine in engines) {
      engine.dispose();
    }
  }
}
