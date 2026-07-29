import 'dart:convert';

// ignore: depend_on_referenced_packages
import 'package:http_parser/http_parser.dart';
import 'package:http/http.dart' as http;
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class _InnerTubeClient {
  static const _baseUrl = 'https://youtubei.googleapis.com/youtubei/v1';
  static final http.Client _client = http.Client();

  /// Generate a random 16-char content playback nonce.
  static String _generateCpn() {
    const chars =
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_!";
    final seed = DateTime.now().microsecondsSinceEpoch;
    return String.fromCharCodes(List.generate(
        16,
        (i) =>
            chars.codeUnitAt(((seed * (i + 1)) + (i * 7919)) % chars.length)));
  }

  static Map<String, dynamic> _buildPayload(String videoId) {
    return {
      'context': {
        'client': {
          'clientName': 'ANDROID',
          'clientVersion': '21.03.38',
          'clientScreen': 'WATCH',
          'platform': 'MOBILE',
          'osName': 'Android',
          'osVersion': '16',
          'androidSdkVersion': 36,
          'hl': 'en',
          'gl': 'US',
          'utcOffsetMinutes': 0,
        },
        'request': {
          'internalExperimentFlags': <dynamic>[],
          'useSsl': true,
        },
        'user': {
          'lockedSafetyMode': false,
        },
      },
      'videoId': videoId,
      'cpn': _generateCpn(),
      'contentCheckOk': true,
      'racyCheckOk': true,
    };
  }

  static Future<Map<String, dynamic>> player(String videoId) async {
    final payload = _buildPayload(videoId);
    AppLogger.log.i(
      '[innertube] request=player videoId=$videoId clientName=${payload['context']['client']['clientName']} clientVersion=${payload['context']['client']['clientVersion']}',
    );
    final response = await _client.post(
      Uri.parse('$_baseUrl/player?prettyPrint=false'),
      headers: {
        'Content-Type': 'application/json',
        'User-Agent':
            'com.google.android.youtube/21.03.38 (Linux; U; Android 16; US) gzip',
        'X-Goog-Api-Format-Version': '2',
      },
      body: jsonEncode(payload),
    );
    if (response.statusCode != 200) {
      final bodySnippet = response.body.length > 500
          ? '${response.body.substring(0, 500)}...'
          : response.body;
      AppLogger.log.w(
        '[innertube] response=player_failed videoId=$videoId status=${response.statusCode} body=$bodySnippet',
      );
      throw Exception(
        'InnerTube player request failed: ${response.statusCode}',
      );
    }
    AppLogger.log.i(
      '[innertube] response=player_ok videoId=$videoId status=${response.statusCode}',
    );
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}

class InnerTubeEngine implements YouTubeEngine {
  static bool get isAvailableForPlatform => true;

  static Future<bool> isInstalled() async => true;

  @override
  Future<Video> getVideo(String videoId) async {
    final data = await _InnerTubeClient.player(videoId);
    return _toVideo(data, videoId);
  }

  @override
  Future<StreamManifest> getStreamManifest(String videoId) async {
    final data = await _InnerTubeClient.player(videoId);
    final streams = _toAudioOnlyStreams(data, videoId);
    return StreamManifest(streams);
  }

  @override
  Future<(Video, StreamManifest)> getVideoWithStreamInfo(
    String videoId,
  ) async {
    final data = await _InnerTubeClient.player(videoId);
    final video = _toVideo(data, videoId);
    final streams = _toAudioOnlyStreams(data, videoId);
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

  Video _toVideo(Map<String, dynamic> data, String videoId) {
    final details = data['videoDetails'] as Map<String, dynamic>? ?? {};
    final title = details['title']?.toString() ?? '';
    final author = details['author']?.toString() ?? '';
    final channelId = details['channelId']?.toString() ?? '';
    final lengthSeconds = details['lengthSeconds']?.toString() ?? '0';
    final duration = Duration(seconds: int.tryParse(lengthSeconds) ?? 0);

    return Video(
      VideoId(videoId),
      title,
      author,
      ChannelId(channelId),
      DateTime.now(),
      DateTime.now().toIso8601String(),
      DateTime.now(),
      details['shortDescription']?.toString() ?? '',
      duration,
      ThumbnailSet(videoId),
      [],
      const Engagement(0, 0, null),
      details['isLive'] == true,
    );
  }

  List<AudioOnlyStreamInfo> _toAudioOnlyStreams(
    Map<String, dynamic> data,
    String videoId,
  ) {
    final result = <AudioOnlyStreamInfo>[];
    final streamingData = data['streamingData'] as Map<String, dynamic>? ?? {};
    final adaptiveFormats =
        streamingData['adaptiveFormats'] as List<dynamic>? ?? [];

    for (final format in adaptiveFormats) {
      final f = format as Map<String, dynamic>;
      final mimeType = f['mimeType']?.toString() ?? '';
      final itag = f['itag'] as int? ?? 0;
      final url = f['url']?.toString();
      final contentLength = f['contentLength']?.toString();
      final bitrate = f['bitrate'] as int? ?? 0;

      if (url == null) continue;

      // Skip video-only streams
      final mimeMain = mimeType.split('/').first;
      if (mimeMain == 'video') continue;

      final container = _parseContainer(mimeType);
      final codec = _parseCodec(mimeType);
      final mediaType = _parseMediaType(mimeType);

      result.add(
        AudioOnlyStreamInfo(
          VideoId(videoId),
          itag,
          Uri.parse(url),
          container,
          contentLength != null
              ? FileSize(int.tryParse(contentLength) ?? 0)
              : FileSize.unknown,
          Bitrate(bitrate),
          codec,
          f['qualityLabel']?.toString() ?? '',
          [],
          mediaType,
          null,
        ),
      );
    }

    return result;
  }

  StreamContainer _parseContainer(String mimeType) {
    final parts = mimeType.split('/');
    if (parts.length >= 2) {
      final sub = parts[1].split(';').first.trim();
      return StreamContainer.parse(sub);
    }
    return StreamContainer.parse('mp4');
  }

  String _parseCodec(String mimeType) {
    final codecMatch = RegExp(r'codecs="([^"]+)"').firstMatch(mimeType);
    if (codecMatch != null) {
      return codecMatch.group(1) ?? 'aac';
    }
    if (mimeType.contains('opus')) return 'opus';
    if (mimeType.contains('mp4a')) return 'mp4a';
    return 'aac';
  }

  MediaType _parseMediaType(String mimeType) {
    final typeAndSub = mimeType.split(';').first.trim();
    if (typeAndSub.contains('/')) {
      return MediaType.parse(typeAndSub);
    }
    return MediaType.parse('audio/mp4');
  }

  @override
  void dispose() {}
}
