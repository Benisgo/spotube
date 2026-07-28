import 'dart:convert';

import 'package:dart_ytmusic_api/dart_ytmusic_api.dart';
import 'package:http_parser/http_parser.dart';
import 'package:http/http.dart' as http;
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// InnerTube client context used by YouTube Music's streaming endpoint.
/// This is needed because dart_ytmusic_api's getSong() doesn't always
/// return adaptiveFormats with URLs. A direct InnerTube /player call
/// reliably returns stream URLs.
class _YtMusicInnerTubeClient {
  static const _baseUrl = 'https://www.youtube.com/youtubei/v1';
  static const _apiKey = 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';
  static final http.Client _client = http.Client();

  static Future<Map<String, dynamic>> player(String videoId) async {
    final payload = {
      'context': {
        'client': {
          'clientName': 'ANDROID',
          'clientVersion': '19.09.37',
          'androidSdkVersion': 30,
          'hl': 'en',
          'gl': 'US',
        },
      },
      'videoId': videoId,
      'playbackContext': {
        'contentPlaybackContext': {'html5Preference': 'HTML5_PREF_WANTS'},
      },
    };
    final response = await _client.post(
      Uri.parse('$_baseUrl/player?key=$_apiKey'),
      headers: {
        'Content-Type': 'application/json',
        'User-Agent':
            'com.google.android.apps.youtube.music/6.30.52 (Linux; Android 11)',
      },
      body: jsonEncode(payload),
    );
    if (response.statusCode != 200) {
      throw Exception(
        'InnerTube (Music) player request failed: ${response.statusCode}',
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}

/// A YouTube engine that resolves streaming URLs via YouTube Music's
/// InnerTube API. Returns direct CDN URLs that are more reliable and
/// faster than yt-dlp extraction.
class YtMusicEngine implements YouTubeEngine {
  YTMusic? _ytmusic;

  Future<YTMusic> _ensureClient() async {
    if (_ytmusic == null) {
      _ytmusic = YTMusic();
      await _ytmusic!.initialize();
    }
    return _ytmusic!;
  }

  static bool get isAvailableForPlatform => true;

  static Future<bool> isInstalled() async => true;

  @override
  Future<Video> getVideo(String videoId) async {
    // Use dart_ytmusic_api for metadata (title, artist, duration)
    final ytmusic = await _ensureClient();
    final song = await ytmusic.getSong(videoId);
    return _toVideo(song, videoId);
  }

  @override
  Future<StreamManifest> getStreamManifest(String videoId) async {
    // Use direct InnerTube call for reliable stream URLs
    // dart_ytmusic_api's getSong() adaptiveFormats often lacks URLs.
    final data = await _YtMusicInnerTubeClient.player(videoId);
    final streams = _toAudioOnlyStreams(data, videoId);
    return StreamManifest(streams);
  }

  @override
  Future<(Video, StreamManifest)> getVideoWithStreamInfo(
    String videoId,
  ) async {
    final ytmusic = await _ensureClient();
    final data = await _YtMusicInnerTubeClient.player(videoId);
    final song = await ytmusic.getSong(videoId);
    final video = _toVideo(song, videoId);
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

    if (result.isEmpty) {
      AppLogger.log.w(
        '[yt_music] no_audio_streams videoId=$videoId',
      );
      throw Exception('No audio streams found for video $videoId');
    }

    return result;
  }

  StreamContainer _parseContainer(String mimeType) {
    final parts = mimeType.split('/');
    if (parts.length >= 2) {
      var sub = parts[1].split(';').first.trim().toLowerCase();
      sub = sub.replaceAll('m4a', 'mp4').replaceAll('ogg', 'webm');
      try {
        return StreamContainer.parse(sub);
      } catch (_) {
        return StreamContainer.parse('mp4');
      }
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

  Video _toVideo(SongFull song, String videoId) {
    return Video(
      VideoId(videoId),
      song.name,
      song.artist.name,
      ChannelId(song.artist.artistId ?? ''),
      DateTime.now(),
      DateTime.now().toIso8601String(),
      DateTime.now(),
      '',
      Duration(seconds: song.duration),
      ThumbnailSet(videoId),
      [],
      const Engagement(0, 0, null),
      false,
    );
  }

  @override
  Future<void> dispose() async {
    _ytmusic = null;
  }
}
