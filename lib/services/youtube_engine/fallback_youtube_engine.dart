import 'dart:async';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class FallbackYouTubeEngine implements YouTubeEngine {
  final List<YouTubeEngine> engines;

  // A global stream that UI can listen to for toast notifications
  static final StreamController<String> fallbackNotifier =
      StreamController<String>.broadcast();

  FallbackYouTubeEngine(this.engines) {
    if (engines.isEmpty) {
      throw ArgumentError('FallbackYouTubeEngine requires at least one engine');
    }
  }

  static bool get isAvailableForPlatform => true;

  static Future<bool> isInstalled() async => true;

  String _engineName(YouTubeEngine engine) => engine.runtimeType.toString();

  @override
  Future<Video> getVideo(String videoId) async {
    for (int i = 0; i < engines.length; i++) {
      final engineName = _engineName(engines[i]);
      AppLogger.log.i(
        '[youtube_engine] attempt=getVideo engine=$engineName index=$i videoId=$videoId',
      );
      try {
        final result = await engines[i].getVideo(videoId);
        AppLogger.log.i(
          '[youtube_engine] success=getVideo engine=$engineName index=$i videoId=$videoId',
        );
        return result;
      } catch (e, stack) {
        AppLogger.log.w(
          '[youtube_engine] failed=getVideo engine=$engineName index=$i videoId=$videoId error=$e',
        );
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
      final engineName = _engineName(engines[i]);
      AppLogger.log.i(
        '[youtube_engine] attempt=getStreamManifest engine=$engineName index=$i videoId=$videoId',
      );
      try {
        final result = await engines[i].getStreamManifest(videoId);
        AppLogger.log.i(
          '[youtube_engine] success=getStreamManifest engine=$engineName index=$i videoId=$videoId audioOnly=${result.audioOnly.length}',
        );
        return result;
      } catch (e, stack) {
        AppLogger.log.w(
          '[youtube_engine] failed=getStreamManifest engine=$engineName index=$i videoId=$videoId error=$e',
        );
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
      final engineName = _engineName(engines[i]);
      AppLogger.log.i(
        '[youtube_engine] attempt=getVideoWithStreamInfo engine=$engineName index=$i videoId=$videoId',
      );
      try {
        final result = await engines[i].getVideoWithStreamInfo(videoId);
        AppLogger.log.i(
          '[youtube_engine] success=getVideoWithStreamInfo engine=$engineName index=$i videoId=$videoId audioOnly=${result.$2.audioOnly.length}',
        );
        return result;
      } catch (e, stack) {
        AppLogger.log.w(
          '[youtube_engine] failed=getVideoWithStreamInfo engine=$engineName index=$i videoId=$videoId error=$e',
        );
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
      final engineName = _engineName(engines[i]);
      AppLogger.log.i(
        '[youtube_engine] attempt=searchVideos engine=$engineName index=$i query=$query',
      );
      try {
        final results = await engines[i].searchVideos(query);
        AppLogger.log.i(
          '[youtube_engine] success=searchVideos engine=$engineName index=$i query=$query results=${results.length}',
        );
        if (results.isNotEmpty) return results;
      } catch (e, stack) {
        AppLogger.log.w(
          '[youtube_engine] failed=searchVideos engine=$engineName index=$i query=$query error=$e',
        );
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
