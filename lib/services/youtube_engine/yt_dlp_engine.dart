import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/youtube_engine/newpipe_engine.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:spotube/services/youtube_engine/youtube_explode_engine.dart';
import 'package:spotube/services/youtube_engine/yt_dlp_binary.dart';
import 'package:spotube/utils/platform.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:yt_dlp_dart/yt_dlp_dart.dart';
// ignore: depend_on_referenced_packages
import 'package:http_parser/http_parser.dart';

class YtDlpEngine implements YouTubeEngine {
  YouTubeEngine get _fallbackEngine {
    if (NewPipeEngine.isAvailableForPlatform) {
      return NewPipeEngine();
    }

    return YouTubeExplodeEngine();
  }

  bool _shouldFallback(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains("too many requests") ||
        message.contains("http error 429") ||
        message.contains("this video is not available") ||
        message.contains("unable to download webpage") ||
        message.contains("no supported javascript runtime") ||
        message.contains("command failed with exit code 1");
  }

  Future<T> _runWithFallback<T>(
    String operation,
    Future<T> Function() primary,
    Future<T> Function(YouTubeEngine fallback) secondary,
  ) async {
    try {
      return await primary();
    } catch (error, stackTrace) {
      if (!_shouldFallback(error)) rethrow;

      final fallback = _fallbackEngine;
      await AppLogger.reportError(
        error,
        stackTrace,
        "yt-dlp $operation failed, falling back to ${fallback.runtimeType}",
      );
      return secondary(fallback);
    }
  }

  StreamManifest _parseFormats(List formats, videoId) {
    final audioOnlyStreams = formats
        .where((f) => f["resolution"] == "audio only")
        .sorted((a, b) => a["quality"] > b["quality"] ? 1 : -1)
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
        Bitrate(
          (((f["abr"] ?? f["tbr"] ?? 0) * 1000) as num).toInt(),
        ),
        f["acodec"] ?? "aac",
        f["format_note"],
        [],
        MediaType.parse(
          "audio/${f["audio_ext"]}",
        ),
        null,
      );
    });

    return StreamManifest(audioOnlyStreams);
  }

  Video _parseInfo(Map<String, dynamic> info) {
    final publishDate = info["upload_date"] != null
        ? DateTime.fromMillisecondsSinceEpoch(
            int.parse(info["upload_date"]) * 1000,
          )
        : DateTime.now();
    return Video(
      VideoId(info["id"]),
      info["title"],
      info["channel"],
      ChannelId(info["channel_id"]),
      publishDate,
      info["upload_date"] as String? ?? DateTime.now().toString(),
      publishDate,
      info["description"] ?? "",
      Duration(seconds: (info["duration"] as num).toInt()),
      ThumbnailSet(info["id"]),
      info["tags"]?.cast<String>() ?? <String>[],
      Engagement(
        info["view_count"],
        info["like_count"],
        null,
      ),
      info["is_live"] ?? false,
    );
  }

  static bool get isAvailableForPlatform => kIsDesktop;

  static Future<bool> isInstalled() async {
    return isAvailableForPlatform &&
        await YtDlpBinary.ensureAvailable(downloadIfMissing: false);
  }

  @override
  Future<StreamManifest> getStreamManifest(String videoId) async {
    return _runWithFallback(
      "stream manifest lookup",
      () async {
        final formats = await YtDlp.instance.extractInfo(
          "https://www.youtube.com/watch?v=$videoId",
          formatSpecifiers: "%(formats)j",
          extraArgs: [
            "--no-check-certificate",
            "--geo-bypass",
            "--quiet",
            "--ignore-errors",
          ],
        ) as List;

        final manifest = _parseFormats(formats, videoId);
        if (manifest.audioOnly.isEmpty) {
          throw Exception("yt-dlp returned no playable audio streams");
        }

        return manifest;
      },
      (fallback) => fallback.getStreamManifest(videoId),
    );
  }

  @override
  Future<Video> getVideo(String videoId) async {
    return _runWithFallback(
      "video lookup",
      () async {
        final info = await YtDlp.instance.extractInfo(
          "https://www.youtube.com/watch?v=$videoId",
          formatSpecifiers: "%()j",
          extraArgs: [
            "--skip-download",
            "--no-check-certificate",
            "--geo-bypass",
            "--quiet",
            "--ignore-errors",
          ],
        ) as Map<String, dynamic>;

        return _parseInfo(info);
      },
      (fallback) => fallback.getVideo(videoId),
    );
  }

  @override
  Future<(Video, StreamManifest)> getVideoWithStreamInfo(String videoId) async {
    return _runWithFallback(
      "video+stream lookup",
      () async {
        final info = await YtDlp.instance.extractInfo(
          "https://www.youtube.com/watch?v=$videoId",
          formatSpecifiers: "%()j",
          extraArgs: [
            "--no-check-certificate",
            "--geo-bypass",
            "--quiet",
            "--ignore-errors",
          ],
        ) as Map<String, dynamic>;

        final manifest = _parseFormats(info["formats"] as List? ?? [], videoId);
        if (manifest.audioOnly.isEmpty) {
          throw Exception("yt-dlp returned no playable audio streams");
        }

        return (_parseInfo(info), manifest);
      },
      (fallback) => fallback.getVideoWithStreamInfo(videoId),
    );
  }

  @override
  Future<List<Video>> searchVideos(String query) async {
    final stdout = await YtDlp.instance.extractInfoString(
      "ytsearch10:$query",
      formatSpecifiers: "%()j",
      extraArgs: [
        "--skip-download",
        "--no-check-certificate",
        "--geo-bypass",
        "--quiet",
        "--ignore-errors",
        "--flat-playlist",
        "--no-playlist",
      ],
    );

    final json = jsonDecode(
      "[${stdout.split("\n").where((s) => s.trim().isNotEmpty).join(",")}]",
    ) as List;

    return json.map((e) => _parseInfo(e)).toList();
  }

  @override
  void dispose() {}
}
