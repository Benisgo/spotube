import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/youtube_engine/yt_botguard.dart';

/// Caching layer on top of [YouTubeBotGuard].
///
/// Provides per-video poTokens with lazy initialization.
/// All methods return null on failure (existing engine continues).
class YouTubePoTokenProvider {
  YouTubePoTokenProvider._();

  static String? _visitorData;
  static bool _initialized = false;

  /// Get a cached or freshly minted poToken for [videoId].
  /// Returns null if BotGuard is unavailable or fails.
  static Future<String?> getToken(String videoId) async {
    try {
      if (!_initialized) {
        final ok = await YouTubeBotGuard.initialize();
        if (!ok) return null;
        _initialized = true;
      }
      return await YouTubeBotGuard.mintPoTokenBounded(videoId);
    } catch (e) {
      AppLogger.log.w("[yt_po_token] getToken failed: $e");
      return null;
    }
  }

  /// Get the session visitorData (fetched during BotGuard init).
  static Future<String?> getVisitorData() async {
    if (_visitorData != null) return _visitorData;
    _visitorData = await YouTubeBotGuard.fetchVisitorData();
    return _visitorData;
  }

  /// Dispose BotGuard and reset state.
  static Future<void> dispose() async {
    await YouTubeBotGuard.dispose();
    _initialized = false;
    _visitorData = null;
  }
}
