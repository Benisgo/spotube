import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/youtube_engine/android_yt_dlp_engine.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:spotube/services/youtube_engine/yt_po_token_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class _NsigDecoder {
  static const _latestPlayerUrl =
      "https://api.pipepipe.dev/decoder/latest-player";
  static const _decodeUrl = "https://api.pipepipe.dev/decoder/decode";
  static const _userAgent = "PipePipe/4.9.0";

  static final http.Client _client = http.Client();

  static String? _playerId;
  static int? _playerIdExpiryMs;

  /// Cached signatureTimestamp from PipePipe API (used by WEB client).
  static int? _signatureTimestamp;

  static final _cache = <String, String>{};

  /// Returns the cached signatureTimestamp (fetched alongside player ID).
  static int? get signatureTimestamp => _signatureTimestamp;

  static Future<String?> _ensurePlayerId() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_playerId != null &&
        _playerIdExpiryMs != null &&
        now < _playerIdExpiryMs!) return _playerId;
    try {
      final resp = await _client.get(Uri.parse(_latestPlayerUrl), headers: {
        "User-Agent": _userAgent
      }).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final id = json["player"] as String?;
      if (id == null || id.isEmpty) return null;
      _playerId = id;
      _playerIdExpiryMs = now + 24 * 60 * 60 * 1000;
      // Extract signatureTimestamp — Flow uses this for clients with useSignatureTimestamp=true
      final sts = json["signatureTimestamp"] as int?;
      if (sts != null && sts > 0) _signatureTimestamp = sts;
      return id;
    } catch (e) {
      AppLogger.log.w("[yt_music_nsig] failed to get player ID: $e");
      return null;
    }
  }

  static Future<String?> decode(String n) async {
    final pid = await _ensurePlayerId();
    if (pid == null) return null;
    final cacheKey = "$pid:$n";
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey];
    try {
      final resp = await _client.get(
          Uri.parse(
              "$_decodeUrl?player=${Uri.encodeComponent(pid)}&n=${Uri.encodeComponent(n)}"),
          headers: {
            "User-Agent": _userAgent
          }).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final decoded = json[n] as String?;
      if (decoded != null && decoded.isNotEmpty) _cache[cacheKey] = decoded;
      return decoded;
    } catch (e) {
      AppLogger.log.w("[yt_music_nsig] failed to decode n param: $e");
      return null;
    }
  }

  static Future<String?> decodeSignature(String s) async {
    final pid = await _ensurePlayerId();
    if (pid == null) return null;
    final cacheKey = "sig:$s";
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey];
    try {
      final resp = await _client.get(
          Uri.parse(
              "$_decodeUrl?player=${Uri.encodeComponent(pid)}&sig=${Uri.encodeComponent(s)}"),
          headers: {
            "User-Agent": _userAgent
          }).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final decoded = json["result"] as String?;
      if (decoded != null && decoded.isNotEmpty) _cache[cacheKey] = decoded;
      return decoded;
    } catch (e) {
      AppLogger.log.w("[yt_music_nsig] failed to decode sig: $e");
      return null;
    }
  }

  static Future<String> applyToUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final n = uri.queryParameters["n"];
    if (n == null || n.isEmpty) return url;
    final decoded = await decode(n);
    if (decoded == null || decoded == n) return url;
    final newQuery = <String, String>{};
    uri.queryParameters.forEach((k, v) {
      newQuery[k] = k == "n" ? decoded : v;
    });
    return uri.replace(queryParameters: newQuery).toString();
  }
}

/// Uses youtube_explode_dart's IOS InnerTube client + PipePipe nsig decode.
class _YtMusicClient {
  static final YoutubeHttpClient _http = YoutubeHttpClient();
  static final _iosClient = YoutubeApiClient.ios;

  /// Cache player responses so getStreamManifest can reuse getVideo's result.
  static final Map<String, Map<String, dynamic>> _playerCache = {};

  static void _cacheResponse(String videoId, Map<String, dynamic> data) {
    _playerCache[videoId] = data;
  }

  static Map<String, dynamic>? _getCachedResponse(String videoId) {
    return _playerCache[videoId];
  }

  /// Custom clients not in youtube_explode_dart.
  static final _visionOs = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'VISIONOS',
        'clientVersion': '0.1',
        'userAgent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15',
        'osName': 'visionOS',
        'osVersion': '1.3.21O771',
        'deviceMake': 'Apple',
        'deviceModel': 'RealityDevice14,1',
        'hl': 'en',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
      },
    },
  }, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  static final _tvSimply = YoutubeApiClient(
    {
      'context': {
        'client': {
          'clientName': 'TVHTML5_SIMPLY',
          'clientVersion': '2.0',
          'userAgent':
              'Mozilla/5.0 (SMART-TV; Linux; Tizen 5.0) AppleWebKit/537.36',
          'hl': 'en',
          'timeZone': 'UTC',
          'gl': 'US',
          'utcOffsetMinutes': 0,
        },
      },
      'contentCheckOk': true,
      'racyCheckOk': true,
    },
    'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
  );

  static final _webEmbedded = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'WEB_EMBEDDED_PLAYER',
        'clientVersion': '1.20260301.00.00',
        'userAgent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        'hl': 'en',
        'timeZone': 'UTC',
        'gl': 'US',
        'utcOffsetMinutes': 0,
        'originalUrl': 'https://www.youtube.com',
      },
    },
  }, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  /// ANDROID_CREATOR — YouTube Studio app, proven to work in Flow.
  static final _androidCreator = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'ANDROID_CREATOR',
        'clientVersion': '25.03.101',
        'userAgent':
            'com.google.android.apps.youtube.creator/25.03.101 (Linux; U; Android 15; en_US; Pixel 9 Pro Fold; Build/AP3A.241005.015.A2; Cronet/132.0.6779.0)',
        'osName': 'Android',
        'osVersion': '15',
        'deviceMake': 'Google',
        'deviceModel': 'Pixel 9 Pro Fold',
        'androidSdkVersion': '35',
        'buildId': 'AP3A.241005.015.A2',
        'cronetVersion': '132.0.6779.0',
        'packageName': 'com.google.android.apps.youtube.creator',
        'hl': 'en',
        'timeZone': 'UTC',
        'gl': 'US',
        'utcOffsetMinutes': 0,
      },
    },
  }, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  /// IPADOS — iPad client, same clientName as IOS but different device fields.
  static final _iPados = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'IOS',
        'clientVersion': '21.03.3',
        'userAgent':
            'com.google.ios.youtube/21.03.3 (iPad7,6; U; CPU iPadOS 17_7_10 like Mac OS X; en-US)',
        'osName': 'iPadOS',
        'osVersion': '17.7.10.21H450',
        'deviceMake': 'Apple',
        'deviceModel': 'iPad7,6',
        'packageName': 'com.google.ios.youtube',
        'hl': 'en',
        'timeZone': 'UTC',
        'gl': 'US',
        'utcOffsetMinutes': 0,
      },
    },
  }, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  /// Cached cookies from the latest InnerTube response (for proxy to use).
  static String _cookies = "";

  /// Last client's UA string, used by headersForStreamUrl to match the CDN.
  static String _lastUA = "";

  /// SharedPreferences key for persisted YouTube auth cookies
  /// (set by the YouTube audio plugin's Hetu auth).
  static const _ytCookiePrefsKey =
      'spotube_plugin.youtube-audio.yt_cookie_header';

  /// Load persisted cookies from the YouTube plugin's LocalStorage
  /// (SharedPreferences) into _cookies.
  static Future<void> loadPersistedCookies() async {
    if (_cookies.isNotEmpty) return; // already have session cookies
    try {
      final prefs = await SharedPreferences.getInstance();
      final persisted = prefs.getString(_ytCookiePrefsKey);
      if (persisted != null && persisted.isNotEmpty) {
        _cookies = persisted;
        AppLogger.log.i("[yt_music] loaded persisted cookies");
      }
    } catch (e) {
      AppLogger.log.w("[yt_music] failed to load persisted cookies: $e");
    }
  }

  /// Parse a named cookie value from a "key1=val1; key2=val2" cookie string.
  static String? _parseCookieValue(String cookieStr, String name) {
    for (final part in cookieStr.split(";")) {
      final trimmed = part.trim();
      if (trimmed.startsWith("$name=")) {
        return trimmed.substring("$name=".length);
      }
    }
    return null;
  }

  /// Add BotGuard poToken + visitorData to a WEB client player request.
  static Future<void> _enrichWithPoToken(
    Map<String, dynamic> payload,
    Map<String, String> requestHeaders,
    Map<String, dynamic> clientCtx,
    String videoId,
  ) async {
    try {
      final token = await YouTubePoTokenProvider.getToken(videoId);
      if (token != null) {
        payload["serviceIntegrityDimensions"] = {"poToken": token};
      }
      final visitorData = await YouTubePoTokenProvider.getVisitorData();
      if (visitorData != null) {
        requestHeaders["X-Goog-Visitor-Id"] = visitorData;
        clientCtx["visitorData"] = visitorData;
      }
    } catch (e) {
      AppLogger.log.w("[yt_music] _enrichWithPoToken failed: $e");
    }
  }

  /// Numeric client IDs for X-YouTube-Client-Name header.
  static const _clientIds = {
    "IOS": "5",
    "ANDROID": "3",
    "ANDROID_VR": "28", // was 50!
    "TVHTML5": "7", // was 85!
    "TVHTML5_SIMPLY": "75",
    "WEB_EMBEDDED_PLAYER": "56",
    "MWEB": "2", // was 100!
    "VISIONOS": "101",
    "ANDROID_CREATOR": "14",
    "WEB": "1",
  };

  /// Client User-Agent strings matching the youtube_explode_dart clients.
  static const _clientUAs = {
    "IOS":
        "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
    "ANDROID_VR":
        "com.google.android.youtube/1.56.21 (Linux; U; Android 12) gzip",
    "ANDROID":
        "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip",
    "TVHTML5": "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version,gzip(gfe)",
    "TVHTML5_SIMPLY":
        "Mozilla/5.0 (SMART-TV; Linux; Tizen 5.0) AppleWebKit/537.36",
    "WEB_EMBEDDED_PLAYER":
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    "MWEB":
        "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.6367.83 Mobile Safari/537.36",
    "VISIONOS":
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
    "ANDROID_CREATOR":
        "com.google.android.apps.youtube.creator/25.03.101 (Linux; U; Android 15; en_US; Pixel 9 Pro Fold; Build/AP3A.241005.015.A2; Cronet/132.0.6779.0)",
    "WEB":
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)",
  };

  /// Returns matching UA + cookies for a googlevideo URL.
  static Map<String, String>? headersForStreamUrl(String url) {
    if (!url.contains("googlevideo.com")) return null;
    final ua = _lastUA.isNotEmpty ? _lastUA : _clientUAs["IOS"]!;
    final headers = <String, String>{
      "user-agent": ua,
      "accept": "*/*",
      "accept-language": "en-US,en;q=0.5",
      "origin": "https://www.youtube.com",
      "referer": "https://www.youtube.com/",
    };
    if (_cookies.isNotEmpty) headers["cookie"] = _cookies;
    return headers;
  }

  /// Try multiple InnerTube clients in order until one returns audio streams.
  static Future<Map<String, dynamic>> player(String videoId,
      {YoutubeApiClient? client}) async {
    // Load persisted cookies from the YouTube plugin's auth system
    await loadPersistedCookies();

    final ytClient = client ?? _iosClient;
    // Deep copy to avoid mutating the original const/final client payloads
    final payload =
        jsonDecode(jsonEncode(ytClient.payload)) as Map<String, dynamic>;
    final clientCtx = payload["context"]["client"] as Map<String, dynamic>;
    final clientName = clientCtx["clientName"] as String? ?? "";

    // Add enriched client fields
    payload["videoId"] = videoId;
    payload["contentCheckOk"] = true;
    payload["racyCheckOk"] = true;
    final sts = _NsigDecoder.signatureTimestamp;
    // Flow sends signatureTimestamp to ALL clients — not just ANDROID/WEB
    if (sts != null) {
      payload["playbackContext"] = {
        "contentPlaybackContext": {"signatureTimestamp": sts},
      };
    }
    // Client-specific fields
    if (clientName == "ANDROID") {
      clientCtx["deviceMake"] = "Google";
      clientCtx["deviceModel"] = "Pixel 6 Pro";
      clientCtx["androidSdkVersion"] = 34;
      clientCtx["osVersion"] = "15";
    } else if (clientName == "WEB") {
      clientCtx["originalUrl"] = "https://www.youtube.com";
      // WEB gets a richer playback context (Flow parity)
      if (sts != null) {
        payload["playbackContext"] = {
          "contentPlaybackContext": {
            "signatureTimestamp": sts,
            "referer": "https://www.youtube.com/watch?v=$videoId",
            "vis": 0,
            "splay": false,
            "lactMilliseconds": "-1",
            "html5Preference": "HTML5_PREF_WANTS",
          },
        };
      }
      // PoToken + visitorData (BotGuard attestation) for WEB client
      // (enrichment happens after requestHeaders is built below)
    }

    AppLogger.log.i(
      "[yt_music] request=player videoId=$videoId "
      "clientName=$clientName "
      "clientVersion=${clientCtx["clientVersion"]}",
    );

    // Build headers with client identity + cookies
    final requestHeaders = <String, String>{
      "Content-Type": "application/json",
      "User-Agent": _clientUAs[clientName] ?? _clientUAs["IOS"]!,
      "X-YouTube-Client-Name": _clientIds[clientName] ?? "",
      "X-YouTube-Client-Version": clientCtx["clientVersion"]?.toString() ?? "",
      "X-Origin": "https://www.youtube.com",
      "Referer": "https://www.youtube.com/",
      "X-Goog-Api-Format-Version": "1",
    };
    if (_cookies.isNotEmpty) {
      requestHeaders["cookie"] = _cookies;
      // SAPISIDHASH Authorization — Flow sends this only for login-capable clients.
      // IOS, TVHTML5, MWEB, WEB, ANDROID_CREATOR support login.
      // ANDROID, ANDROID_VR, VISIONOS — sending auth to them causes 400.
      final loginCapable = {"IOS", "TVHTML5", "MWEB", "WEB", "ANDROID_CREATOR"};
      if (loginCapable.contains(clientName)) {
        final sapisid = _parseCookieValue(_cookies, "SAPISID");
        if (sapisid != null) {
          final epochSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          final origin = "https://www.youtube.com";
          final hash = crypto.sha1
              .convert(utf8.encode("$epochSec $sapisid $origin"))
              .toString();
          requestHeaders["Authorization"] = "SAPISIDHASH ${epochSec}_$hash";
        }
      }
    }

    // PoToken + visitorData enrichment for WEB client only (requires requestHeaders)
    if (clientName == "WEB") {
      await _enrichWithPoToken(payload, requestHeaders, clientCtx, videoId);
    }

    final response = await _http.post(
      Uri.parse(ytClient.apiUrl),
      headers: requestHeaders,
      body: jsonEncode(payload),
    );

    // Store cookies (name=value only, strip attributes) + UA for proxy.
    // Handle multiple Set-Cookie headers (joined by newlines in Dart http).
    final setCookie = response.headers["set-cookie"];
    if (setCookie != null && setCookie.isNotEmpty) {
      final allCookies = setCookie
          .split("\n")
          .map((c) {
            final trimmed = c.trim();
            final semi = trimmed.indexOf(";");
            return semi > 0 ? trimmed.substring(0, semi).trim() : trimmed;
          })
          .where((c) => c.isNotEmpty)
          .toList();
      if (allCookies.isNotEmpty) {
        _cookies = allCookies.join("; ");
      }
    }
    _lastUA = _clientUAs[clientName] ?? _clientUAs["IOS"]!;

    if (response.statusCode != 200) {
      AppLogger.log.w(
          "[yt_music] fail videoId=$videoId client=$clientName status=${response.statusCode}");
      throw Exception(
          "YouTube Music player request failed: ${response.statusCode}");
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final sd = data["streamingData"] as Map<String, dynamic>?;
    final ps = data["playabilityStatus"] as Map<String, dynamic>?;
    final psStatus = ps?["status"]?.toString() ?? "missing";
    final psReason = ps?["reason"]?.toString() ?? "";
    AppLogger.log.i(
        "[yt_music] response videoId=$videoId client=$clientName playability=$psStatus reason=$psReason");
    final af = sd?["adaptiveFormats"] as List? ?? [];
    final fmts = sd?["formats"] as List? ?? [];
    if (af.isEmpty && fmts.isEmpty) {
      AppLogger.log.w(
          "[yt_music] empty_streams videoId=$videoId client=$clientName playability=$psStatus reason=$psReason hasStreamingData=${data.containsKey("streamingData")}");
    }

    return {
      "videoId": videoId,
      "formats": fmts,
      "adaptiveFormats": af,
      "videoDetails": data["videoDetails"] ?? {},
    };
  }
}

class YtMusicEngine implements YouTubeEngine {
  static bool get isAvailableForPlatform => true;
  static Future<bool> isInstalled() async => true;

  @override
  Future<Video> getVideo(String videoId) async {
    for (final client in [
      YoutubeApiClient.ios,
      YoutubeApiClient.androidVr,
      YoutubeApiClient.android,
      _YtMusicClient._visionOs,
      YoutubeApiClient.tv,
      _YtMusicClient._tvSimply,
      _YtMusicClient._webEmbedded,
      _YtMusicClient._androidCreator,
      _YtMusicClient._iPados,
      YoutubeApiClient.mweb,
      YoutubeApiClient.safari,
    ]) {
      try {
        final data = await _YtMusicClient.player(videoId, client: client);
        final vd = data["videoDetails"] as Map<String, dynamic>?;
        if (vd != null &&
            vd.containsKey("title") &&
            (vd["lengthSeconds"]?.toString() ?? "0") != "0") {
          // Cache only valid responses (with videoDetails) for getStreamManifest reuse
          final sd = data["streamingData"] as Map<String, dynamic>?;
          if (sd != null) _YtMusicClient._cacheResponse(videoId, data);
          return _toVideo(data, videoId);
        }
      } catch (_) {
        continue;
      }
    }
    // Fallback: use YoutubeExplode for metadata
    final yt = YoutubeExplode();
    try {
      return await yt.videos.get(videoId);
    } finally {
      yt.close();
    }
  }

  @override
  Future<StreamManifest> getStreamManifest(String videoId) async {
    // Check cache first (getVideo may have already fetched this)
    final cached = _YtMusicClient._getCachedResponse(videoId);
    if (cached != null) {
      final streams = await _toAudioOnlyStreams(cached, videoId);
      if (streams.isNotEmpty) {
        AppLogger.log.i(
            "[yt_music] cached_streams videoId=$videoId audio=${streams.length}");
        return StreamManifest(streams);
      }
    }

    // Prewarm BotGuard in background while we try other clients
    YouTubePoTokenProvider.getVisitorData();

    // ANDROID + WEB first (best for audio + poToken auth). IOS/MWEB as backup.
    for (final client in [
      YoutubeApiClient.android,
      YoutubeApiClient.safari,
      YoutubeApiClient.ios,
      YoutubeApiClient.mweb,
      YoutubeApiClient.androidVr,
      _YtMusicClient._visionOs,
      YoutubeApiClient.tv,
      _YtMusicClient._tvSimply,
      _YtMusicClient._webEmbedded,
      _YtMusicClient._androidCreator,
      _YtMusicClient._iPados,
    ]) {
      final name = client.payload["context"]["client"]["clientName"];
      try {
        final data = await _YtMusicClient.player(videoId, client: client);
        final streams = await _toAudioOnlyStreams(data, videoId);
        if (streams.isNotEmpty) {
          AppLogger.log.i(
              "[yt_music] client_ok videoId=$videoId client=$name audio=${streams.length}");
          return StreamManifest(streams);
        }
        AppLogger.log
            .i("[yt_music] client_no_audio videoId=$videoId client=$name");
      } catch (e) {
        AppLogger.log
            .i("[yt_music] client_fail videoId=$videoId client=$name error=$e");
        continue;
      }
    }
    AppLogger.log
        .i("[yt_music] fallback_streams videoId=$videoId to YoutubeExplode");
    final yt = YoutubeExplode();
    try {
      return await yt.videos.streamsClient.getManifest(videoId);
    } finally {
      yt.close();
    }
  }

  @override
  Future<(Video, StreamManifest)> getVideoWithStreamInfo(String videoId) async {
    Map<String, dynamic>? data;
    String? usedClientName;
    for (final client in [
      YoutubeApiClient.ios,
      YoutubeApiClient.androidVr,
      YoutubeApiClient.android,
      _YtMusicClient._visionOs,
      YoutubeApiClient.tv,
      _YtMusicClient._tvSimply,
      _YtMusicClient._webEmbedded,
      _YtMusicClient._androidCreator,
      _YtMusicClient._iPados,
      YoutubeApiClient.mweb,
      YoutubeApiClient.safari,
    ]) {
      final name = client.payload["context"]["client"]["clientName"];
      try {
        data = await _YtMusicClient.player(videoId, client: client);
        usedClientName = name;
        break;
      } catch (e) {
        AppLogger.log.i(
            "[yt_music] gvsi_client_fail videoId=$videoId client=$name error=$e");
        continue;
      }
    }
    if (data == null) {
      AppLogger.log.i(
          "[yt_music] fallback_all videoId=$videoId all_clients_failed to YoutubeExplode");
      final yt = YoutubeExplode();
      try {
        final video = await yt.videos.get(videoId);
        final manifest = await yt.videos.streamsClient.getManifest(videoId);
        return (video, manifest);
      } finally {
        yt.close();
      }
    }
    Video video;
    final vd = data["videoDetails"] as Map<String, dynamic>?;
    if (vd != null &&
        vd.containsKey("title") &&
        (vd["lengthSeconds"]?.toString() ?? "0") != "0") {
      video = _toVideo(data, videoId);
    } else {
      final yt = YoutubeExplode();
      try {
        video = await yt.videos.get(videoId);
      } finally {
        yt.close();
      }
    }
    final streams = await _toAudioOnlyStreams(data, videoId);
    if (streams.isNotEmpty) {
      AppLogger.log.i(
          "[yt_music] gvsi_client_ok videoId=$videoId client=$usedClientName audio=${streams.length}");
      return (video, StreamManifest(streams));
    }
    AppLogger.log.i(
        "[yt_music] fallback_all_streams videoId=$videoId client=$usedClientName no_audio to YoutubeExplode");
    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      return (video, manifest);
    } finally {
      yt.close();
    }
  }

  @override
  Future<List<Video>> searchVideos(String query) async {
    final yt = YoutubeExplode();
    try {
      return await yt.search.search(query);
    } finally {
      yt.close();
    }
  }

  Future<List<AudioOnlyStreamInfo>> _toAudioOnlyStreams(
      Map<String, dynamic> data, String videoId) async {
    final result = <AudioOnlyStreamInfo>[];
    final adaptiveFormats = data["adaptiveFormats"] as List? ?? [];
    final formats = data["formats"] as List? ?? [];

    AppLogger.log.i(
        "[yt_music] format_counts videoId=$videoId adaptive=${adaptiveFormats.length} formats=${formats.length}");

    for (final list in [adaptiveFormats, formats]) {
      for (int i = 0; i < list.length; i++) {
        final f = list[i] as Map<String, dynamic>;
        final mimeType = f["mimeType"]?.toString() ?? "";

        // Log first 10 formats details regardless of video/audio type
        if (i < 20) {
          final u = f["url"]?.toString();
          AppLogger.log.i(
              "[yt_music] debug_fmt[$i] videoId=$videoId list=${list == adaptiveFormats ? "adaptive" : "formats"} "
              "hasUrl=${f.containsKey("url")} "
              "hasSigCipher=${f.containsKey("signatureCipher")} "
              "hasCipher=${f.containsKey("cipher")} "
              "hasAudioQuality=${f.containsKey("audioQuality")} "
              "mime=$mimeType itag=${f["itag"]} "
              "url=${u != null ? "${u.substring(0, u.length.clamp(0, 60))}..." : "null"}");
        }

        // Accept audio-only OR combined formats (video+audio). Combined formats
        // like itag=18 (avc1 + mp4a) have mimeType starting with "video/".
        final isAudioOnly = mimeType.startsWith("audio/");
        final hasAudioCodec = mimeType.contains("mp4a") ||
            mimeType.contains("opus") ||
            mimeType.contains("mp3");
        final hasAudioQuality = f.containsKey("audioQuality");
        if (!isAudioOnly && !hasAudioCodec && !hasAudioQuality) continue;
        var url = f["url"]?.toString();

        if (url == null) {
          final cipher =
              f["signatureCipher"]?.toString() ?? f["cipher"]?.toString();
          if (cipher != null) {
            try {
              final params = Uri.splitQueryString(cipher);
              url = params["url"]!;
              // Reconstruct URL: keep all cipher params, remove obfuscated sig
              final allParams = <String, String>{};
              final sp = params["sp"];
              final s = params["s"];
              params.forEach((k, v) {
                // Exclude url, sp, s, and any param matching sp (obfuscated sig)
                if (k != "url" && k != "sp" && k != "s" && k != sp) {
                  allParams[k] = v;
                }
              });
              if (sp != null && s != null && sp.isNotEmpty && s.isNotEmpty) {
                // Try PipePipe sig decode; skip format if decoding fails
                final decodedSig = await _NsigDecoder.decodeSignature(s);
                if (decodedSig == null) {
                  if (i < 20) {
                    AppLogger.log.i("[yt_music] sig_skip[$i] videoId=$videoId "
                        "rawLen=${s.length} (PipePipe decoder unavailable)");
                  }
                  continue; // skip this format — sig undecodable
                }
                allParams[sp] = decodedSig;
                if (i < 20) {
                  AppLogger.log
                      .i("[yt_music] sig_decode[$i] videoId=$videoId sp=$sp "
                          "rawLen=${s.length} decodedLen=${decodedSig.length}");
                }
              }
              url =
                  Uri.parse(url).replace(queryParameters: allParams).toString();
            } catch (_) {
              continue;
            }
          }
        }
        if (url == null && i < 20) {
          AppLogger.log.i(
              "[yt_music] debug_skip[$i] videoId=$videoId no_url_after_cipher list=${list == adaptiveFormats ? "adaptive" : "formats"}");
        }
        if (url == null) continue;

        if (i < 20) {
          AppLogger.log.i("[yt_music] debug_url[$i] videoId=$videoId "
              "url=${url.length > 120 ? "${url.substring(0, 120)}..." : url} "
              "hasNSig=${url.contains("&n=") || url.contains("?n=")} "
              "hasSig=${url.contains("&sig=") || url.contains("?sig=")}");
        }

        url = await _NsigDecoder.applyToUrl(url);

        // Quick HEAD verify — ciphered URLs need full 2s for sig decode,
        // direct URLs get 0.5s to catch bad nsig without slowing playback
        final hadCipher =
            f.containsKey("signatureCipher") || f.containsKey("cipher");
        try {
          final headResp = await _YtMusicClient._http
              .head(Uri.parse(url))
              .timeout(Duration(seconds: hadCipher ? 2 : 1));
          if (headResp.statusCode == 403) {
            if (i < 20) {
              AppLogger.log.i("[yt_music] verify_403[$i] videoId=$videoId");
            }
            continue;
          }
        } catch (_) {
          if (i < 20) {
            AppLogger.log.i("[yt_music] verify_fail[$i] videoId=$videoId");
          }
          continue;
        }

        // Store cookies + browser headers for the proxy to use
        final h = _YtMusicClient.headersForStreamUrl(url);
        if (h != null) {
          AndroidYtDlpEngine.setHeadersForUrl(url, h);
        }

        result.add(AudioOnlyStreamInfo(
          VideoId(videoId),
          f["itag"] as int? ?? 0,
          Uri.parse(url),
          _parseContainer(mimeType),
          f["contentLength"] != null
              ? FileSize(int.tryParse(f["contentLength"].toString()) ?? 0)
              : FileSize.unknown,
          Bitrate(f["bitrate"] as int? ?? 0),
          _parseCodec(mimeType),
          f["qualityLabel"]?.toString() ?? "",
          [],
          _parseMediaType(mimeType),
          null,
        ));
        // Found one working stream — no need to check more
        break;
      }
      if (result.isNotEmpty) break;
    }

    if (result.isEmpty) {
      AppLogger.log.w(
          "[yt_music] no_audio_streams videoId=$videoId adaptiveFormats=${adaptiveFormats.length} formats=${formats.length}");
      throw Exception("No audio streams found for video $videoId");
    }
    return result;
  }

  StreamContainer _parseContainer(String m) {
    final p = m.split("/");
    if (p.length >= 2) {
      var s = p[1]
          .split(";")
          .first
          .trim()
          .toLowerCase()
          .replaceAll("m4a", "mp4")
          .replaceAll("ogg", "webm");
      try {
        return StreamContainer.parse(s);
      } catch (_) {
        return StreamContainer.parse("mp4");
      }
    }
    return StreamContainer.parse("mp4");
  }

  String _parseCodec(String m) {
    final c = RegExp(r'codecs="([^"]+)"').firstMatch(m);
    if (c != null) return c.group(1)!;
    if (m.contains("opus")) return "opus";
    if (m.contains("mp4a")) return "mp4a";
    return "aac";
  }

  MediaType _parseMediaType(String m) {
    final t = m.split(";").first.trim();
    return t.contains("/") ? MediaType.parse(t) : MediaType.parse("audio/mp4");
  }

  Video _toVideo(Map<String, dynamic> data, String videoId) {
    final d = data["videoDetails"] as Map<String, dynamic>? ?? {};
    return Video(
      VideoId(videoId),
      d["title"]?.toString() ?? "",
      d["author"]?.toString() ?? "",
      ChannelId(d["channelId"]?.toString() ?? ""),
      DateTime.now(),
      DateTime.now().toIso8601String(),
      DateTime.now(),
      "",
      Duration(
          seconds: int.tryParse(d["lengthSeconds"]?.toString() ?? "0") ?? 0),
      ThumbnailSet(videoId),
      [],
      const Engagement(0, 0, null),
      false,
    );
  }

  @override
  Future<void> dispose() async {}
}
