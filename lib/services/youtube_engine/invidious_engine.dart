import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class InvidiousEngine implements YouTubeEngine {
  static const String _defaultInstance = "https://inv.thepixora.com";

  final Dio _dio;
  final String _instance;

  InvidiousEngine({String? instanceUrl})
      : _instance =
            (instanceUrl ?? _defaultInstance).replaceAll(RegExp(r'/$'), ''),
        _dio = Dio(
          BaseOptions(
            validateStatus: (_) => true,
            headers: {
              'Accept': 'application/json',
              'Accept-Language': 'en-US,en;q=0.9',
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            },
          ),
        );

  static bool get isAvailableForPlatform => true;

  static Future<bool> isInstalled() async => true;

  Map<String, dynamic> _decodeMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is String) {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) return decoded;
    }
    throw Exception('Invidious instance $_instance returned unexpected data');
  }

  List<dynamic> _decodeList(dynamic data) {
    if (data is List<dynamic>) return data;
    if (data is String) {
      final decoded = jsonDecode(data);
      if (decoded is List<dynamic>) return decoded;
    }
    throw Exception('Invidious instance $_instance returned unexpected data');
  }

  @override
  Future<Video> getVideo(String videoId) async {
    final response = await _dio.get('$_instance/api/v1/videos/$videoId');
    return _parseVideo(_decodeMap(response.data));
  }

  @override
  Future<StreamManifest> getStreamManifest(String videoId) async {
    final response = await _dio.get('$_instance/api/v1/videos/$videoId');
    final data = _decodeMap(response.data);

    final formats = (data['adaptiveFormats'] as List<dynamic>?) ?? [];
    final audioStreams = formats
        .map((f) => f as Map<String, dynamic>)
        .where((f) => _isAudioFormat(f))
        .map((f) => _parseAudioStream(f, videoId));

    return StreamManifest(audioStreams);
  }

  bool _isAudioFormat(Map<String, dynamic> format) {
    final type = (format['type'] as String?) ?? '';
    if (type.startsWith('audio/')) return true;
    if (format.containsKey('audioQuality') || format.containsKey('audioSampleRate')) return true;
    if (format['resolution'] == null && format['width'] == null && format['height'] == null) {
      final mimeType = type.split(';').first.trim();
      return mimeType.contains('audio') || format['bitrate'] != null;
    }
    return false;
  }

  @override
  Future<(Video, StreamManifest)> getVideoWithStreamInfo(
    String videoId,
  ) async {
    final response = await _dio.get('$_instance/api/v1/videos/$videoId');
    final data = _decodeMap(response.data);

    final video = _parseVideo(data);

    final formats = (data['adaptiveFormats'] as List<dynamic>?) ?? [];
    final audioStreams = formats
        .map((f) => f as Map<String, dynamic>)
        .where((f) => _isAudioFormat(f))
        .map((f) => _parseAudioStream(f, videoId));

    return (video, StreamManifest(audioStreams));
  }

  @override
  Future<List<Video>> searchVideos(String query) async {
    final response = await _dio.get(
      '$_instance/api/v1/search',
      queryParameters: {'q': query, 'type': 'video'},
    );

    final results = _decodeList(response.data);
    return results
        .whereType<Map<String, dynamic>>()
        .map(_parseSearchResult)
        .toList();
  }

  Video _parseVideo(Map<String, dynamic> data) {
    final videoId = data['videoId'] as String;
    final published = data['published'] as int?;

    return Video(
      VideoId(videoId),
      data['title'] as String? ?? '',
      data['author'] as String? ?? '',
      _parseChannelId(data['authorId'] as String?),
      published != null
          ? DateTime.fromMillisecondsSinceEpoch(published * 1000)
          : null,
      data['publishedText'] as String? ?? '',
      published != null
          ? DateTime.fromMillisecondsSinceEpoch(published * 1000)
          : null,
      data['description'] as String? ?? '',
      Duration(seconds: (data['lengthSeconds'] as num?)?.toInt() ?? 0),
      ThumbnailSet(videoId),
      (data['keywords'] as List<dynamic>?)?.cast<String>() ?? [],
      Engagement(
        (data['viewCount'] as num?)?.toInt() ?? 0,
        data['likeCount'] as int?,
        data['dislikeCount'] as int?,
      ),
      !((data['liveNow'] as bool?) ?? false),
    );
  }

  Video _parseSearchResult(Map<String, dynamic> data) {
    final videoId = data['videoId'] as String;
    final published = data['published'] as int?;

    return Video(
      VideoId(videoId),
      data['title'] as String? ?? '',
      data['author'] as String? ?? '',
      _parseChannelId(data['authorId'] as String?),
      published != null
          ? DateTime.fromMillisecondsSinceEpoch(published * 1000)
          : null,
      data['publishedText'] as String? ?? '',
      published != null
          ? DateTime.fromMillisecondsSinceEpoch(published * 1000)
          : null,
      data['description'] as String? ?? '',
      Duration(seconds: (data['lengthSeconds'] as num?)?.toInt() ?? 0),
      ThumbnailSet(videoId),
      [],
      Engagement(
        (data['viewCount'] as num?)?.toInt() ?? 0,
        null,
        null,
      ),
      !((data['liveNow'] as bool?) ?? false),
    );
  }

  AudioOnlyStreamInfo _parseAudioStream(
    Map<String, dynamic> format,
    String videoId,
  ) {
    final type = (format['type'] as String?) ?? '';
    final rawBitrate = format['bitrate'];
    final bitrate = rawBitrate is String ? int.tryParse(rawBitrate) ?? 0 : (rawBitrate as num?)?.toInt() ?? 0;
    final container = (format['container'] as String?) ?? 'mp4';
    
    final rawItag = format['itag'];
    final itag = rawItag is String ? int.tryParse(rawItag) ?? 0 : (rawItag as num?)?.toInt() ?? 0;
    
    final proxyUrl = '$_instance/latest_version?id=$videoId&itag=$itag&local=true';

    return AudioOnlyStreamInfo(
      VideoId(videoId),
      itag,
      Uri.parse(proxyUrl),
      _parseContainer(container),
      FileSize.unknown,
      Bitrate(bitrate),
      format['encoding'] as String? ?? '',
      switch (bitrate) {
        > 130 * 1024 => "high",
        > 64 * 1024 => "medium",
        _ => "low",
      },
      [],
      MediaType.parse(type.split(';').first),
      null,
    );
  }

  static ChannelId _parseChannelId(String? id) {
    if (id != null && id.length == 24 && id.startsWith('UC')) {
      return ChannelId(id);
    }
    return ChannelId('UC0000000000000000000000');
  }

  static StreamContainer _parseContainer(String name) {
    return switch (name.toLowerCase()) {
      'mp4' || 'm4a' || 'm4v' => StreamContainer.mp4,
      'webm' => StreamContainer.webM,
      '3gpp' => StreamContainer.tgpp,
      _ => StreamContainer.mp4,
    };
  }

  @override
  void dispose() {
    _dio.close();
  }
}
