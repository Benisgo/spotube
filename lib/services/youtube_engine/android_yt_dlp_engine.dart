import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import 'package:http_parser/http_parser.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:spotube/utils/platform.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class AndroidYtDlpEngine implements YouTubeEngine {
  static const _channel = MethodChannel("oss.krtirtho.spotube/yt_dlp");

  /// Cache of yt-dlp http_headers per CDN URL, needed because YouTube's CDN
  /// rejects requests that don't carry the exact headers yt-dlp extracted.
  static final _headersByUrl = <String, Map<String, String>>{};

  /// Returns the yt-dlp http_headers for a given CDN URL, if cached.
  static Map<String, String>? headersForUrl(String url) {
    return _headersByUrl[url];
  }

  /// Store headers for a CDN URL so the proxy can use them when fetching.
  static void setHeadersForUrl(String url, Map<String, String> headers) {
    _headersByUrl[url] = headers;
  }

  static const _extractionTimeout = Duration(seconds: 45);

  StreamManifest _parseFormats(List? formats, videoId) {
    formats ??= [];
    final audioOnlyStreams = formats
        .where((f) => f["resolution"] == "audio only" || f["vcodec"] == "none")
        .where((f) => f["url"] != null)
        .sorted((a, b) => (a["quality"] ?? 0) > (b["quality"] ?? 0) ? 1 : -1)
        .map((f) {
      final filesize = f["filesize"] ?? f["filesize_approx"];
      final url = f["url"] as String;
      if (f["http_headers"] != null) {
        _headersByUrl[url] = (f["http_headers"] as Map).map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        );
      }
      return AudioOnlyStreamInfo(
        VideoId(videoId),
        0,
        Uri.parse(url),
        StreamContainer.parse(
          f["container"]?.replaceAll("_dash", "").replaceAll("m4a", "mp4") ??
              (f["protocol"] == "m3u8_native" ? "m3u8" : "mp4"),
        ),
        filesize != null ? FileSize(filesize) : FileSize.unknown,
        Bitrate((((f["abr"] ?? f["tbr"] ?? 0) * 1000) as num).toInt()),
        f["acodec"] ?? "aac",
        f["format_note"],
        [],
        MediaType.parse("audio/${f["audio_ext"] ?? "mp4"}"),
        null,
      );
    });

    return StreamManifest(audioOnlyStreams);
  }

  Video _parseInfo(Map<String, dynamic> info) {
    final uploadDate = info["upload_date"] as String?;
    final publishDate = uploadDate != null
        ? DateTime(
            int.parse(uploadDate.substring(0, 4)),
            int.parse(uploadDate.substring(4, 6)),
            int.parse(uploadDate.substring(6, 8)),
          )
        : DateTime.now();

    return Video(
      VideoId(info["id"]),
      info["title"],
      info["channel"] ?? info["uploader"] ?? "",
      ChannelId(info["channel_id"] ?? info["uploader_id"] ?? ""),
      publishDate,
      uploadDate ?? publishDate.toIso8601String(),
      publishDate,
      info["description"] ?? "",
      Duration(seconds: ((info["duration"] ?? 0) as num).toInt()),
      ThumbnailSet(info["id"]),
      info["tags"]?.cast<String>() ?? <String>[],
      Engagement(info["view_count"], info["like_count"], null),
      info["is_live"] ?? false,
    );
  }

  Future<Map<String, dynamic>> _extractInfo(String url) async {
    final stdout = await _channel.invokeMethod<String>(
      "extractInfo",
      {
        "url": url,
        "extraArgs": [
          "--no-check-certificate",
          "--quiet",
          "--ignore-errors",
          "--no-playlist",
        ],
      },
    ).timeout(_extractionTimeout);

    return jsonDecode(stdout ?? "{}") as Map<String, dynamic>;
  }

  static bool get isAvailableForPlatform => kIsAndroid;

  static Future<bool> isInstalled() async {
    if (!isAvailableForPlatform) return false;
    return await _channel.invokeMethod<bool>("isAvailable") ?? false;
  }

  static Future<void> update() async {
    if (!isAvailableForPlatform) return;
    await _channel.invokeMethod("update");
  }

  @override
  Future<StreamManifest> getStreamManifest(String videoId) async {
    final info = await _extractInfo("https://www.youtube.com/watch?v=$videoId");
    return _parseFormats(info["formats"] as List, videoId);
  }

  @override
  Future<Video> getVideo(String videoId) async {
    final info = await _extractInfo("https://www.youtube.com/watch?v=$videoId");
    return _parseInfo(info);
  }

  @override
  Future<(Video, StreamManifest)> getVideoWithStreamInfo(String videoId) async {
    final info = await _extractInfo("https://www.youtube.com/watch?v=$videoId");
    return (_parseInfo(info), _parseFormats(info["formats"] as List, videoId));
  }

  @override
  Future<List<Video>> searchVideos(String query) async {
    final stdout = await _channel.invokeMethod<String>(
      "extractInfo",
      {
        "url": "ytsearch10:$query",
        "extraArgs": [
          "--no-check-certificate",
          "--quiet",
          "--ignore-errors",
          "--flat-playlist",
        ],
      },
    ).timeout(_extractionTimeout);

    final lines = (stdout ?? "")
        .split("\n")
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    // Parse line-by-line so a single malformed line doesn't break all results
    final items = <Map<String, dynamic>>[];
    for (final line in lines) {
      try {
        items.add(jsonDecode(line) as Map<String, dynamic>);
      } catch (_) {
        // Skip malformed lines
      }
    }

    return items
        .map((item) => item.cast<String, dynamic>())
        .map(_parseInfo)
        .toList();
  }

  @override
  void dispose() {}
}
