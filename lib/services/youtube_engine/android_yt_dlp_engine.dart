import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import 'package:http_parser/http_parser.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:spotube/utils/platform.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class AndroidYtDlpEngine implements YouTubeEngine {
  static const _channel = MethodChannel("oss.krtirtho.spotube/yt_dlp");

  StreamManifest _parseFormats(List formats, videoId) {
    final audioOnlyStreams = formats
        .where((f) => f["resolution"] == "audio only" || f["vcodec"] == "none")
        .where((f) => f["url"] != null)
        .sorted((a, b) => (a["quality"] ?? 0) > (b["quality"] ?? 0) ? 1 : -1)
        .map((f) {
      final filesize = f["filesize"] ?? f["filesize_approx"];
      return AudioOnlyStreamInfo(
        VideoId(videoId),
        0,
        Uri.parse(f["url"]),
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
    );

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
    );

    final items = jsonDecode(
      "[${(stdout ?? "").split("\n").where((s) => s.trim().isNotEmpty).join(",")}]",
    ) as List;

    return items
        .map((item) => (item as Map).cast<String, dynamic>())
        .map(_parseInfo)
        .toList();
  }

  @override
  void dispose() {}
}
