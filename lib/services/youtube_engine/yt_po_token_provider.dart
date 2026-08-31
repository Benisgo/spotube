import 'package:shared_preferences/shared_preferences.dart';
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

  /// SharedPreferences keys for persisting visitorData across restarts so a
  /// cold start doesn't re-fetch it (and so clients aren't anonymous bots).
  static const _visitorDataPrefsKey = 'youtube_engine.visitor_data';
  static const _visitorDataPrefsAtKey = 'youtube_engine.visitor_data_at';
  static const _visitorDataTtl = Duration(hours: 24);

  static Future<String?> _loadPersistedVisitorData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_visitorDataPrefsKey);
      final savedAt = prefs.getInt(_visitorDataPrefsAtKey);
      if (saved == null || savedAt == null) return null;
      final age = DateTime.now().millisecondsSinceEpoch - savedAt;
      if (age > _visitorDataTtl.inMilliseconds) return null;
      return saved;
    } catch (e) {
      AppLogger.log.w("[yt_po_token] load persisted visitorData failed: $e");
      return null;
    }
  }

  static Future<void> _persistVisitorData(String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_visitorDataPrefsKey, value);
      await prefs.setInt(
        _visitorDataPrefsAtKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      AppLogger.log.w("[yt_po_token] persist visitorData failed: $e");
    }
  }

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

  /// Get the session visitorData (cached, then persisted, then fetched).
  static Future<String?> getVisitorData() async {
    if (_visitorData != null) return _visitorData;
    _visitorData = await _loadPersistedVisitorData();
    if (_visitorData != null) return _visitorData;
    _visitorData = await YouTubeBotGuard.fetchVisitorData();
    if (_visitorData != null) {
      await _persistVisitorData(_visitorData!);
    }
    return _visitorData;
  }

  /// Dispose BotGuard and reset state.
  static Future<void> dispose() async {
    await YouTubeBotGuard.dispose();
    _initialized = false;
    _visitorData = null;
  }
}
