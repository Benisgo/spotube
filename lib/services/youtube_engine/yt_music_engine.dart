import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

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
        now < _playerIdExpiryMs!) {
      return _playerId;
    }
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
  /// Short TTL so a throttled/dead CDN URL isn't reused forever — after it
  /// expires the next play re-fetches a fresh player response, which usually
  /// yields a new signed URL (and often a different CDN node).
  static final Map<String, Map<String, dynamic>> _playerCache = {};
  static final Map<String, DateTime> _playerCacheAt = {};
  static const _playerCacheTtl = Duration(minutes: 10);

  static void _cacheResponse(String videoId, Map<String, dynamic> data) {
    _playerCache[videoId] = data;
    _playerCacheAt[videoId] = DateTime.now();
  }

  static Map<String, dynamic>? _getCachedResponse(String videoId) {
    final cachedAt = _playerCacheAt[videoId];
    if (cachedAt == null) return null;
    if (DateTime.now().difference(cachedAt) > _playerCacheTtl) {
      _playerCache.remove(videoId);
      _playerCacheAt.remove(videoId);
      return null;
    }
    return _playerCache[videoId];
  }

  /// Custom clients not in youtube_explode_dart.
  static const _visionOs = YoutubeApiClient({
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

  static const _tvSimply = YoutubeApiClient(
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

  static const _webEmbedded = YoutubeApiClient({
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
  static const _androidCreator = YoutubeApiClient({
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
  static const _iPados = YoutubeApiClient({
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

  /// Random 16-char client playback nonce (base64-url charset) — same shape
  /// YouTube's own apps send. Flow attaches a cpn to every player request so
  /// the request looks like a real playback session instead of a scraper.
  static String _generateCpn() {
    const charset =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    final random = Random.secure();
    return List.generate(
      16,
      (_) => charset[random.nextInt(charset.length)],
    ).join();
  }

  /// Gate for verbose per-format debug logging (debug_fmt/debug_url/probe).
  /// Default OFF — these logs build huge strings on the main isolate and
  /// caused major jank on mobile (debug builds). Flip to true to diagnose
  /// format-level resolution issues.
  static bool _verbose = false;

  /// SharedPreferences key for persisted YouTube auth cookies
  /// (set by the YouTube audio plugin's Hetu auth).
  static const _ytCookiePrefsKey =
      'spotube_plugin.youtube-audio.yt_cookie_header';

  /// Ensure we have at least anonymous visitor cookies for the CDN. The
  /// ANDROID player response often sets none, yet googlevideo requires a
  /// cookie to serve actual media (1-byte probes pass without one). Flow gets
  /// these from YouTube the same way — we fetch them from youtube.com.
  static Future<void> _ensureStreamCookies() async {
    if (_cookies.isNotEmpty) return;
    try {
      final resp = await _http.get(
        Uri.parse("https://www.youtube.com/"),
        headers: {
          "User-Agent": _clientUAs["IOS"]!,
          "Accept-Language": "en-US,en;q=0.5",
        },
      ).timeout(const Duration(seconds: 8));
      final setCookie = resp.headers["set-cookie"];
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
          AppLogger.log
              .i("[yt_music] captured visitor cookies (${allCookies.length})");
        }
      }
    } catch (e) {
      AppLogger.log.w("[yt_music] failed to fetch visitor cookies: $e");
    }
  }

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

  /// Returns matching UA + cookies for a googlevideo URL. Mirrors Flow's
  /// native fetch: the client UA + cookies, but NO browser `origin`/`referer`
  /// headers — googlevideo rejects those on ANDROID-signed URLs as a client
  /// mismatch (this was the source of the audio-only 403s).
  static Map<String, String>? headersForStreamUrl(String url) {
    if (!url.contains("googlevideo.com")) return null;
    final ua = _lastUA.isNotEmpty ? _lastUA : _clientUAs["IOS"]!;
    final headers = <String, String>{
      "user-agent": ua,
      "accept": "*/*",
      "accept-language": "en-US,en;q=0.5",
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
    // Flow parity: attach a per-request client playback nonce (cpn) so the
    // request carries a real playback-session signature, not a scraper's.
    payload["cpn"] = _generateCpn();
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
          const origin = "https://www.youtube.com";
          final hash = crypto.sha1
              .convert(utf8.encode("$epochSec $sapisid $origin"))
              .toString();
          requestHeaders["Authorization"] = "SAPISIDHASH ${epochSec}_$hash";
        }
      }
    }

    // Attach session visitorData only to the WEB client (which also gets a
    // BotGuard poToken). Earlier attempts to attach X-Goog-Visitor-Id to
    // ANDROID_VR/ANDROID/IOS/MWEB/ANDROID_CREATOR caused those clients to flip
    // from playable to LOGIN_REQUIRED on this user's IP, so non-WEB clients
    // stay in their known-working anonymous wire format.
    if (clientName == "WEB") {
      await _enrichWithPoToken(payload, requestHeaders, clientCtx, videoId);
    }

    // Cap per-client latency. YouTube DELIBERATELY delays rejection responses
    // (LOGIN_REQUIRED/UNPLAYABLE) by ~18s to discourage scraping; a working
    // client returns streamingData promptly (<10s even on slow links). Timing
    // out here mainly kills slow denials and moves the client loop forward —
    // it is NOT a blacklist (a client that would work still responds fast).
    // The TimeoutException is caught by the caller's client loop.
    final response = await _http
        .post(
          Uri.parse(ytClient.apiUrl),
          headers: requestHeaders,
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 10));

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

    // Decode the (potentially multi-MB) player response off the main isolate.
    // On mobile this JSON parse is one of the biggest frame-loop blockers
    // (Skipped 300+ frames while resolving). bodyBytes is sendable, so the
    // parse runs on a fresh isolate and only the decoded map comes back.
    final data = await Isolate.run(
      () => jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
    );
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

  /// YouTube Music (WEB_REMIX) client context for `next`/`browse` calls.
  static final Map<String, dynamic> _webRemixContext = {
    "context": {
      "client": {
        "clientName": "WEB_REMIX",
        "clientVersion": "1.20241223.01.00",
        "hl": "en",
        "gl": "US",
      },
    },
  };

  static const _musicNextUrl =
      "https://music.youtube.com/youtubei/v1/next?prettyPrint=false";
  static const _musicBrowseUrl =
      "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false";

  /// Headers for YouTube Music WEB_REMIX API calls (mirrors Flow's InnerTube).
  static Map<String, String> _musicHeaders() {
    final headers = <String, String>{
      "Content-Type": "application/json",
      "User-Agent": _clientUAs["WEB"] ?? _clientUAs["IOS"]!,
      "X-YouTube-Client-Name": "67", // WEB_REMIX
      "X-YouTube-Client-Version": "1.20241223.01.00",
      "X-Origin": "https://music.youtube.com",
      "Referer": "https://music.youtube.com/",
      "X-Goog-Api-Format-Version": "1",
    };
    if (_cookies.isNotEmpty) headers["cookie"] = _cookies;
    return headers;
  }

  /// Find the lyrics browse endpoint in a `next` response (Flow's approach).
  /// Modern responses put it in the watch-next tabs with
  /// `MUSIC_PAGE_TYPE_TRACK_LYRICS`; older ones in `engagementPanels`.
  static ({String browseId, String? params})? _findLyricsEndpoint(
      Map<String, dynamic> data) {
    // Location 1: watch-next tabbed results — find the "Lyrics" tab.
    try {
      final wn = data["contents"]?["singleColumnMusicWatchNextResultsRenderer"]
          ?["tabbedRenderer"]?["watchNextTabbedResultsRenderer"];
      final tabs = (wn is Map) ? (wn["tabs"] as List?) : null;
      if (tabs != null) {
        for (final tab in tabs) {
          final be = (tab is Map)
              ? (tab["tabRenderer"]?["endpoint"]?["browseEndpoint"] as Map?)
              : null;
          if (be == null) continue;
          final browseId = be["browseId"] as String?;
          if (browseId == null) continue;
          final pageType = be["browseEndpointContextSupportedConfigs"]
              ?["browseEndpointContextMusicConfig"]?["pageType"] as String?;
          // Title is a plain string in modern responses, a runs map in older.
          final rawTitle = (tab as Map)["tabRenderer"]?["title"];
          final String? title = rawTitle is String ? rawTitle : null;
          if (pageType == "MUSIC_PAGE_TYPE_TRACK_LYRICS" || title == "Lyrics") {
            return (browseId: browseId, params: be["params"] as String?);
          }
        }
      }
    } catch (_) {}

    // Location 2: engagementPanels → searchable lyrics panel.
    try {
      final panels = data["engagementPanels"] as List?;
      if (panels != null) {
        for (final panel in panels) {
          final pr = (panel is Map)
              ? (panel["engagementPanelSectionListRenderer"] as Map?)
              : null;
          final panelId = pr?["panelIdentifier"] as String?;
          if (panelId != null && panelId.toLowerCase().contains("lyrics")) {
            final be = pr?["header"]?["engagementPanelTitleHeaderRenderer"]
                ?["navigationEndpoint"]?["browseEndpoint"] as Map?;
            final browseId = be?["browseId"] as String?;
            final params = be?["params"] as String?;
            if (browseId != null) {
              return (browseId: browseId, params: params);
            }
          }
        }
      }
    } catch (_) {}

    return null;
  }

  /// Extract plain-text lyrics from a `browse` response. Returns null when the
  /// panel reports lyrics are unavailable (messageRenderer) or the shape is
  /// unexpected.
  static String? _extractLyricsText(Map<String, dynamic> data) {
    try {
      final contents = data["contents"] as Map?;
      final sectionList = contents?["sectionListRenderer"] as Map?;
      final items = sectionList?["contents"] as List?;
      if (items != null && items.isNotEmpty) {
        final first = items.first;
        final desc = (first is Map)
            ? (first["musicDescriptionShelfRenderer"]?["description"] as Map?)
            : null;
        if (desc != null) {
          final runs = desc["runs"] as List?;
          if (runs != null && runs.isNotEmpty) {
            final text =
                runs.map((r) => (r as Map)["text"]?.toString() ?? "").join();
            if (text.trim().isNotEmpty) return text;
          }
          final simpleText = desc["simpleText"] as String?;
          if (simpleText != null && simpleText.trim().isNotEmpty) {
            return simpleText;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Fetch lyrics for a video from YouTube Music's native lyrics panel
  /// (Flow's approach): `next` to find the lyrics browse endpoint, then
  /// `browse` to read the plain-text lyrics. Returns null if unavailable.
  static Future<String?> fetchLyrics(String videoId) async {
    try {
      // 1. `next` → locate the lyrics browse endpoint.
      final nextRes = await _http.post(
        Uri.parse(_musicNextUrl),
        headers: _musicHeaders(),
        body: jsonEncode({
          ..._webRemixContext,
          "videoId": videoId,
          "playlistId": null,
        }),
      );
      if (nextRes.statusCode != 200) return null;
      final nextData = jsonDecode(nextRes.body) as Map<String, dynamic>;
      final endpoint = _findLyricsEndpoint(nextData);
      if (endpoint == null) return null;

      // 2. `browse` → read the lyrics panel text.
      final browseRes = await _http.post(
        Uri.parse(_musicBrowseUrl),
        headers: _musicHeaders(),
        body: jsonEncode({
          ..._webRemixContext,
          "browseId": endpoint.browseId,
          if (endpoint.params != null) "params": endpoint.params,
        }),
      );
      if (browseRes.statusCode != 200) return null;
      final browseData = jsonDecode(browseRes.body) as Map<String, dynamic>;
      return _extractLyricsText(browseData);
    } catch (e) {
      AppLogger.log.w("[yt_music] fetchLyrics failed for $videoId: $e");
      return null;
    }
  }
}

class YtMusicEngine implements YouTubeEngine {
  static bool get isAvailableForPlatform => true;
  static Future<bool> isInstalled() async => true;

  /// Fetch lyrics for a video from YouTube Music's native lyrics panel
  /// (Flow parity). Returns null when unavailable. Plain text only — synced
  /// lyrics come from LRCLib/SimpMusic providers.
  static Future<String?> fetchLyrics(String videoId) {
    return _YtMusicClient.fetchLyrics(videoId);
  }

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

    // Flow parity: Flow's FAST_DIRECT_STREAM_CLIENTS tries ANDROID_VR first,
    // then MOBILE, IOS, ANDROID_CREATOR. ANDROID_VR-minted URLs serve audio
    // content freely in regions where ANDROID-minted URLs are content-locked
    // (403), so ANDROID_VR must come first for both playback and downloads.
    //
    // Resolution latency matters: on slow mobile networks each InnerTube
    // player request takes 8-18s, and rejected clients (LOGIN_REQUIRED /
    // UNPLAYABLE) are deliberately slow-rolled. Racing the first 3 clients
    // reaches a working client in ~18s instead of ~32s sequentially, so mpv
    // (network-timeout=60) waits on a warm resolve instead of a long cold one.
    Future<StreamManifest?> _tryClient(YoutubeApiClient client) async {
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
      }
      return null;
    }

    final clients = [
      YoutubeApiClient.androidVr, // Flow's primary fast client
      YoutubeApiClient.mweb, // MOBILE
      YoutubeApiClient.ios, // IOS
      _YtMusicClient
          ._androidCreator, // YouTube Studio app — proven to work in Flow
      YoutubeApiClient.android, // ANDROID_CREATOR-ish
      YoutubeApiClient.safari, // WEB
      _YtMusicClient._visionOs,
      YoutubeApiClient.tv,
      _YtMusicClient._tvSimply,
      _YtMusicClient._webEmbedded,
      _YtMusicClient._iPados,
    ];

    // Quiet-first: fire IOS ALONE before any ladder. On flagged IPs (gcr=eg)
    // IOS is the only client that returns playable audio — the other first-
    // wave clients (ANDROID_VR, MWEB, ANDROID_CREATOR) are guaranteed fails
    // (bot-wall / "reload page" / "sign in"), and their concurrent burst is
    // what bot-walls the IP. A bot-walled IP then bot-walls youtube_explode's
    // mux fallback at play time, which is why first-try playback skipped.
    // Resolving with a single IOS request keeps the IP quiet, so the mux
    // fallback (when the audio-only URL 403s at the CDN) succeeds on the
    // first try — and resolution is ~5s faster (IOS answers in ~1s, the
    // ladder's guaranteed losers are slow-rolled to ~6s). Only widen to the
    // ladder if IOS itself fails.
    final iosClient = clients.firstWhere(
      (c) => c.payload["context"]["client"]["clientName"] == "IOS",
    );
    final iosManifest = await _tryClient(iosClient);
    if (iosManifest != null) return iosManifest;

    final rest = clients
        .where((c) => c.payload["context"]["client"]["clientName"] != "IOS")
        .toList();
    final firstWaveResults = await Future.wait(rest.take(4).map(_tryClient));
    for (final manifest in firstWaveResults) {
      if (manifest != null) return manifest;
    }
    for (final client in rest.skip(4)) {
      final manifest = await _tryClient(client);
      if (manifest != null) return manifest;
    }
    // Every InnerTube client failed — typically a bot wall (LOGIN_REQUIRED /
    // UNPLAYABLE) on a flagged IP. THROW instead of silently falling back to
    // YoutubeExplode: FallbackYouTubeEngine catches this and advances to the
    // next engine (yt-dlp, NewPipe), whereas a YoutubeExplode manifest here
    // just ships region-locked URLs that 403 at the CDN (then mux → MPV fail).
    throw Exception(
      "[yt_music] all InnerTube clients failed for videoId=$videoId "
      "(bot wall / no playable audio)",
    );
  }

  @override
  Future<(Video, StreamManifest)> getVideoWithStreamInfo(String videoId) async {
    Map<String, dynamic>? data;
    String? usedClientName;
    // Flow parity: ANDROID_VR first, then MOBILE, IOS, ANDROID_CREATOR — the
    // same order Flow's FAST_DIRECT_STREAM_CLIENTS uses for both playback and
    // downloads.
    for (final client in [
      YoutubeApiClient.androidVr,
      YoutubeApiClient.mweb,
      YoutubeApiClient.ios,
      YoutubeApiClient.android,
      _YtMusicClient._visionOs,
      YoutubeApiClient.tv,
      _YtMusicClient._tvSimply,
      _YtMusicClient._webEmbedded,
      _YtMusicClient._androidCreator,
      _YtMusicClient._iPados,
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
      // All InnerTube clients failed (bot wall). Throw so the engine chain
      // advances instead of falling back to YoutubeExplode.
      throw Exception(
        "[yt_music] getVideoWithStreamInfo: all InnerTube clients failed "
        "for videoId=$videoId (bot wall)",
      );
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
    // Client responded but returned no playable audio. Throw so the engine
    // chain advances to the next engine instead of swallowing into
    // YoutubeExplode (which yields region-locked URLs on this setup).
    throw Exception(
      "[yt_music] getVideoWithStreamInfo: client=$usedClientName returned "
      "no audio for videoId=$videoId",
    );
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
    // googlevideo serves 1-byte validation probes without a cookie but 403s
    // requests that return actual media content unless a session cookie is
    // sent (some regions, e.g. gcr=eg, enforce this). Flow works because it
    // carries the anonymous visitor cookie — ensure we have one too.
    await _YtMusicClient._ensureStreamCookies();

    final result = <AudioOnlyStreamInfo>[];
    final adaptiveFormats = data["adaptiveFormats"] as List? ?? [];
    final formats = data["formats"] as List? ?? [];

    AppLogger.log.i(
        "[yt_music] format_counts videoId=$videoId adaptive=${adaptiveFormats.length} formats=${formats.length}");

    // Pass 1 collects strictly audio-only streams (mimeType starts with
    // "audio/"). Video muxes (video/ + audio codec) are NOT treated as
    // audio — they are only used as a last resort in pass 2 below. This
    // mirrors Flow: audio-only file instead of a 25MB video mux.
    //
    // Resolution is split into two phases so the expensive network steps
    // (n-sig decode + CDN probe) run IN PARALLEL for every candidate. The old
    // code probed each itag sequentially (up to 4s each) → a track took N×4s
    // to resolve. On mobile (slow CPU, debug build) that made mpv give up
    // ("Failed to open") and cascade through the queue. Parallel probing cuts
    // total resolve time down to roughly one probe round-trip.
    final candidates = <({
      Map<String, dynamic> f,
      String mime,
      String url,
    })>[];
    for (final list in [adaptiveFormats, formats]) {
      for (int i = 0; i < list.length; i++) {
        final f = list[i] as Map<String, dynamic>;
        final mimeType = f["mimeType"]?.toString() ?? "";

        if (_YtMusicClient._verbose && i < 20) {
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

        if (!mimeType.startsWith("audio/")) continue;
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
                  if (_YtMusicClient._verbose && i < 20) {
                    AppLogger.log.i("[yt_music] sig_skip[$i] videoId=$videoId "
                        "rawLen=${s.length} (PipePipe decoder unavailable)");
                  }
                  continue; // skip this format — sig undecodable
                }
                allParams[sp] = decodedSig;
                if (_YtMusicClient._verbose && i < 20) {
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
        if (url == null) {
          if (_YtMusicClient._verbose && i < 20) {
            AppLogger.log.i(
                "[yt_music] debug_skip[$i] videoId=$videoId no_url_after_cipher list=${list == adaptiveFormats ? "adaptive" : "formats"}");
          }
          continue;
        }

        if (_YtMusicClient._verbose && i < 20) {
          AppLogger.log.i("[yt_music] debug_url[$i] videoId=$videoId "
              "url=${url.length > 120 ? "${url.substring(0, 120)}..." : url} "
              "hasNSig=${url.contains("&n=") || url.contains("?n=")} "
              "hasSig=${url.contains("&sig=") || url.contains("?sig=")}");
        }

        candidates.add((f: f, mime: mimeType, url: url));
      }
    }

    // Verify all candidates with a ranged GET using the same headers the
    // shelf proxy will send, fired IN PARALLEL. HEAD is UNRELIABLE for
    // googlevideo: youtube_explode's client sends a desktop Chrome UA, which
    // 403s ANDROID-signed URLs even when the URL is perfectly fine on a real
    // GET. So probe the actual GET path instead: an explicit 403 → drop this
    // stream so pass 2 can fall back to a working video mux; timeout/network
    // error → keep it, the proxy will retry and fall back itself.
    if (candidates.isNotEmpty) {
      final resolved = await Future.wait(candidates.map((c) async {
        final url = await _NsigDecoder.applyToUrl(c.url);

        // Store cookies + browser headers for the proxy to use, keyed to the
        // FINAL (n-sig decoded) URL that the proxy will actually fetch.
        final h = _YtMusicClient.headersForStreamUrl(url);
        if (h != null) {
          // Store under both the raw url and Uri.toString() so the proxy's
          // lookup (by activeTrack.url == Uri.toString()) always finds the
          // native-client headers instead of falling back to a Chrome UA —
          // a Chrome UA on an ANDROID-signed URL is what the CDN 403s.
          AndroidYtDlpEngine.setHeadersForUrl(url, h);
          AndroidYtDlpEngine.setHeadersForUrl(Uri.parse(url).toString(), h);
        }

        var status = 0;
        try {
          final probe = await _YtMusicClient._http.get(
            Uri.parse(url),
            headers: {...?h, 'Range': 'bytes=0-0'},
          ).timeout(const Duration(seconds: 3));
          status = probe.statusCode;
          if (_YtMusicClient._verbose) {
            AppLogger.log
                .i("[yt_music] probe itag=${c.f["itag"]} status=$status");
            if (status == 403) {
              AppLogger.log.i(
                  "[yt_music] verify_403_drop itag=${c.f["itag"]} (GET 403; audio URL rejected — falling back to mux)");
            }
          }
        } catch (e) {
          if (_YtMusicClient._verbose) {
            AppLogger.log
                .i("[yt_music] probe_fail itag=${c.f["itag"]} error=$e");
          }
          // Timeout/network — keep the stream; the shelf proxy will retry.
        }
        return (c: c, url: url, status: status);
      }));

      // Add non-403 streams, preserving the original adaptive-then-formats
      // ordering (callers sort by preference later).
      for (final r in resolved) {
        if (r.status == 403) continue;
        final c = r.c;
        result.add(AudioOnlyStreamInfo(
          VideoId(videoId),
          c.f["itag"] as int? ?? 0,
          Uri.parse(r.url),
          _parseContainer(c.mime),
          c.f["contentLength"] != null
              ? FileSize(int.tryParse(c.f["contentLength"].toString()) ?? 0)
              : FileSize.unknown,
          Bitrate(c.f["bitrate"] as int? ?? 0),
          _parseCodec(c.mime),
          c.f["qualityLabel"]?.toString() ?? "",
          [],
          _parseMediaType(c.mime),
          null,
        ));
      }
    }

    // Pass 2 — strict last resort: only when NO audio-only stream is usable,
    // fall back to a single video mux (video+audio combined) so the song
    // still plays. A mux never appears in the manifest when audio-only
    // streams exist — so downloads/cache stay audio-only.
    if (result.isEmpty) {
      for (final list in [adaptiveFormats, formats]) {
        for (int i = 0; i < list.length; i++) {
          final f = list[i] as Map<String, dynamic>;
          final mimeType = f["mimeType"]?.toString() ?? "";
          final hasAudioCodec = mimeType.contains("mp4a") ||
              mimeType.contains("opus") ||
              mimeType.contains("mp3");
          final hasAudioQuality = f.containsKey("audioQuality");
          if (mimeType.startsWith("audio/") ||
              (!hasAudioCodec && !hasAudioQuality)) {
            continue;
          }
          var url = f["url"]?.toString();
          if (url == null) {
            final cipher =
                f["signatureCipher"]?.toString() ?? f["cipher"]?.toString();
            if (cipher != null) {
              try {
                final params = Uri.splitQueryString(cipher);
                url = params["url"]!;
                final allParams = <String, String>{};
                final sp = params["sp"];
                final s = params["s"];
                params.forEach((k, v) {
                  if (k != "url" && k != "sp" && k != "s" && k != sp) {
                    allParams[k] = v;
                  }
                });
                if (sp != null && s != null && sp.isNotEmpty && s.isNotEmpty) {
                  final decodedSig = await _NsigDecoder.decodeSignature(s);
                  if (decodedSig != null) allParams[sp] = decodedSig;
                }
                url = Uri.parse(url)
                    .replace(queryParameters: allParams)
                    .toString();
              } catch (_) {
                url = null;
              }
            }
          }
          if (url == null) continue;
          url = await _NsigDecoder.applyToUrl(url);
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
          AppLogger.log.i(
              "[yt_music] mux_fallback videoId=$videoId itag=${f["itag"]} (no audio-only streams)");
          break;
        }
        if (result.isNotEmpty) break;
      }
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
