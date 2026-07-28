import 'package:dart_ytmusic_api/dart_ytmusic_api.dart';
import 'package:http_parser/http_parser.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

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
    final ytmusic = await _ensureClient();
    final song = await ytmusic.getSong(videoId);
    return _toVideo(song, videoId);
  }

  @override
  Future<StreamManifest> getStreamManifest(String videoId) async {
    final ytmusic = await _ensureClient();
    final song = await ytmusic.getSong(videoId);
    final streams = _toAudioOnlyStreams(song.adaptiveFormats, videoId);
    return StreamManifest(streams);
  }

  @override
  Future<(Video, StreamManifest)> getVideoWithStreamInfo(
    String videoId,
  ) async {
    final ytmusic = await _ensureClient();
    final song = await ytmusic.getSong(videoId);
    final video = _toVideo(song, videoId);
    final streams = _toAudioOnlyStreams(song.adaptiveFormats, videoId);
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
    List<dynamic> adaptiveFormats,
    String videoId,
  ) {
    final result = <AudioOnlyStreamInfo>[];

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
