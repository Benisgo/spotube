import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class VeromeEngine implements YouTubeEngine {
  static const String _defaultInstance = "https://verome-api.deno.dev";

  final Dio _dio;
  final String _instance;

  VeromeEngine({String? instanceUrl})
      : _instance =
            (instanceUrl ?? _defaultInstance).replaceAll(RegExp(r'/$'), ''),
        _dio = Dio(
          BaseOptions(
            validateStatus: (_) => true,
            headers: {'Accept': 'application/json'},
          ),
        );

  static bool get isAvailableForPlatform => true;

  static Future<bool> isInstalled() async => true;

  void _checkResponse(Response response) {
    if (response.statusCode != 200) {
      throw Exception(
        'Verome API $_instance returned status ${response.statusCode}',
      );
    }
  }

  @override
  Future<Video> getVideo(String videoId) async {
    final response =
        await _dio.get('$_instance/api/stream', queryParameters: {'id': videoId});
    _checkResponse(response);
    final data = response.data as Map<String, dynamic>;
    final meta = data['metadata'] as Map<String, dynamic>?;
    if (meta == null) throw Exception('No metadata in Verome response');
    return _parseVideo(meta, videoId);
  }

  @override
  Future<StreamManifest> getStreamManifest(String videoId) async {
    final response =
        await _dio.get('$_instance/api/stream', queryParameters: {'id': videoId});
    _checkResponse(response);
    final data = response.data as Map<String, dynamic>;

    final urls = (data['streamingUrls'] as List<dynamic>?) ?? [];
    final audioStreams = urls
        .map((u) => u as Map<String, dynamic>)
        .map((u) => _parseAudioStream(u, videoId));

    return StreamManifest(audioStreams);
  }

  @override
  Future<(Video, StreamManifest)> getVideoWithStreamInfo(
    String videoId,
  ) async {
    final response =
        await _dio.get('$_instance/api/stream', queryParameters: {'id': videoId});
    _checkResponse(response);
    final data = response.data as Map<String, dynamic>;
    final meta = data['metadata'] as Map<String, dynamic>?;
    if (meta == null) throw Exception('No metadata in Verome response');

    final video = _parseVideo(meta, videoId);

    final urls = (data['streamingUrls'] as List<dynamic>?) ?? [];
    final audioStreams = urls
        .map((u) => u as Map<String, dynamic>)
        .map((u) => _parseAudioStream(u, videoId));

    return (video, StreamManifest(audioStreams));
  }

  @override
  Future<List<Video>> searchVideos(String query) async {
    final response = await _dio.get(
      '$_instance/api/yt_search',
      queryParameters: {'q': query, 'filter': 'videos'},
    );
    _checkResponse(response);

    final data = response.data as Map<String, dynamic>;
    final results = (data['results'] as List<dynamic>?) ?? [];

    return results
        .whereType<Map<String, dynamic>>()
        .map(_parseSearchResult)
        .toList();
  }

  Video _parseVideo(Map<String, dynamic> meta, String videoId) {
    return Video(
      VideoId(videoId),
      meta['title'] as String? ?? '',
      meta['author'] as String? ?? '',
      _parseChannelId(null),
      null,
      '',
      null,
      '',
      Duration(seconds: (meta['lengthSeconds'] as num?)?.toInt() ?? 0),
      ThumbnailSet(videoId),
      [],
      Engagement(
        (meta['viewCount'] as num?)?.toInt() ?? 0,
        null,
        null,
      ),
      true,
    );
  }

  Video _parseSearchResult(Map<String, dynamic> item) {
    final videoId = item['id'] as String;
    final channel = item['channel'] as Map<String, dynamic>?;

    return Video(
      VideoId(videoId),
      item['title'] as String? ?? '',
      channel?['name'] as String? ?? '',
       _parseChannelId(channel?['id'] as String?),
      null,
      '',
      null,
      '',
      _parseDuration(item['duration'] as String?),
      ThumbnailSet(videoId),
      [],
      Engagement(0, null, null),
      true,
    );
  }

  Duration _parseDuration(String? duration) {
    if (duration == null || duration.isEmpty) return Duration.zero;
    final parts = duration.split(':').map(int.tryParse).toList();
    if (parts.length == 3) {
      return Duration(
        hours: parts[0] ?? 0,
        minutes: parts[1] ?? 0,
        seconds: parts[2] ?? 0,
      );
    } else if (parts.length == 2) {
      return Duration(
        minutes: parts[0] ?? 0,
        seconds: parts[1] ?? 0,
      );
    }
    return Duration.zero;
  }

  AudioOnlyStreamInfo _parseAudioStream(
    Map<String, dynamic> stream,
    String videoId,
  ) {
    final type = (stream['type'] as String?) ?? '';
    final bitrateStr = (stream['bitrate'] as String?) ?? '0';
    final bitrate = int.tryParse(bitrateStr) ?? 0;

    final urlStr = (stream['url'] as String?) ??
        (stream['directUrl'] as String?) ??
        '';

    return AudioOnlyStreamInfo(
      VideoId(videoId),
      int.tryParse((stream['itag'] as String?) ?? '0') ?? 0,
      Uri.parse(urlStr),
      _parseContainer(type),
      FileSize.unknown,
      Bitrate(bitrate),
      type.contains('opus') ? 'opus' : 'mp4a.40.2',
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

  static StreamContainer _parseContainer(String mimeType) {
    return switch (mimeType) {
      final t when t.contains('webm') => StreamContainer.webM,
      _ => StreamContainer.mp4,
    };
  }

  @override
  void dispose() {
    _dio.close();
  }
}
