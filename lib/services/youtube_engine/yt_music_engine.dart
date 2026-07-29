import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class _NsigDecoder {
  static const _latestPlayerUrl =
      "https://api.pipepipe.dev/decoder/latest-player";
  static const _decodeUrl = "https://api.pipepipe.dev/decoder/decode";
  static const _userAgent = "PipePipe/4.9.0";

  static final http.Client _client = http.Client();
  static String? _playerId;
  static int? _playerIdExpiryMs;
  static final _cache = <String, String>{};

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

  static Future<Map<String, dynamic>> player(String videoId) async {
    final payload = Map<String, dynamic>.from(_iosClient.payload);
    payload["videoId"] = videoId;
    payload["contentCheckOk"] = true;
    payload["racyCheckOk"] = true;

    AppLogger.log.i(
      "[yt_music] request=player videoId=$videoId "
      "clientName=${payload["context"]["client"]["clientName"]} "
      "clientVersion=${payload["context"]["client"]["clientVersion"]}",
    );

    final response = await _http.post(
      Uri.parse(_iosClient.apiUrl),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode(payload),
    );

    if (response.statusCode != 200) {
      final snippet = response.body.length > 500
          ? "${response.body.substring(0, 500)}..."
          : response.body;
      AppLogger.log.w(
          "[yt_music] response=player_failed videoId=$videoId status=${response.statusCode} body=$snippet");
      throw Exception(
          "YouTube Music player request failed: ${response.statusCode}");
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final sd = data["streamingData"] as Map<String, dynamic>?;
    final af = sd?["adaptiveFormats"] as List? ?? [];
    final fmts = sd?["formats"] as List? ?? [];
    AppLogger.log.i(
        "[yt_music] response=player_ok videoId=$videoId adaptiveFormats=${af.length} formats=${fmts.length}");

    // Log first 3 formats for debugging
    for (int i = 0; i < [af.length, 3].reduce((a, b) => a < b ? a : b); i++) {
      final f = af[i] as Map<String, dynamic>;
      AppLogger.log.i(
          "[yt_music] fmt[$i] mimeType=${f["mimeType"]} hasUrl=${f.containsKey("url")} hasCipher=${f.containsKey("signatureCipher") || f.containsKey("cipher")} itag=${f["itag"]} keys=${f.keys.join(",")}");
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
    final data = await _YtMusicClient.player(videoId);
    return _toVideo(data, videoId);
  }

  @override
  Future<StreamManifest> getStreamManifest(String videoId) async {
    final data = await _YtMusicClient.player(videoId);
    final streams = await _toAudioOnlyStreams(data, videoId);
    return StreamManifest(streams);
  }

  @override
  Future<(Video, StreamManifest)> getVideoWithStreamInfo(String videoId) async {
    final data = await _YtMusicClient.player(videoId);
    final video = _toVideo(data, videoId);
    final streams = await _toAudioOnlyStreams(data, videoId);
    return (video, StreamManifest(streams));
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

    for (final list in [adaptiveFormats, formats]) {
      for (final format in list) {
        final f = format as Map<String, dynamic>;
        final mimeType = f["mimeType"]?.toString() ?? "";
        if (mimeType.split("/").first == "video") continue;
        var url = f["url"]?.toString();

        if (url == null) {
          final cipher =
              f["signatureCipher"]?.toString() ?? f["cipher"]?.toString();
          if (cipher != null) {
            try {
              url = Uri.splitQueryString(cipher)["url"];
            } catch (_) {
              continue;
            }
          }
        }
        if (url == null) continue;

        url = await _NsigDecoder.applyToUrl(url);

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
