import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart' hide Response;
import 'package:dio/dio.dart' as dio_lib;
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:path/path.dart';
import 'package:shelf/shelf.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/models/parser/range_headers.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/audio_player/state.dart';

import 'package:spotube/provider/server/active_track_sources.dart';
import 'package:spotube/provider/server/sourced_track_provider.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/sourced_track/sourced_track.dart';
import 'package:spotube/utils/service_utils.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

final _deviceClients = Set.unmodifiable({
  YoutubeApiClient.ios,
  YoutubeApiClient.android,
  YoutubeApiClient.mweb,
  YoutubeApiClient.safari,
});

String? get _randomUserAgent => _deviceClients
    .elementAt(
      Random().nextInt(_deviceClients.length),
    )
    .payload["context"]["client"]["userAgent"];

class ServerPlaybackRoutes {
  final Ref ref;
  UserPreferences get userPreferences => ref.read(userPreferencesProvider);
  AudioPlayerState get playlist => ref.read(audioPlayerProvider);
  final Dio dio;

  ServerPlaybackRoutes(this.ref) : dio = Dio();

  bool _isPlaybackRequestRelevant(String requestedUri) {
    return requestedUri == audioPlayer.currentSource ||
        requestedUri == audioPlayer.nextSource;
  }

  void _ensurePlaybackRequestRelevant(String requestedUri) {
    if (_isPlaybackRequestRelevant(requestedUri)) return;

    throw StateError("Stale playback request: $requestedUri");
  }

  Future<String> _getTrackCacheFilePath(SourcedTrack track) async {
    return join(
      await UserPreferencesNotifier.getMusicCacheDir(),
      ServiceUtils.sanitizeFilename(
        '${track.query.name} - ${track.query.artists.map((d) => d.name).join(",")} (${track.info.id}).${track.qualityPreset!.getFileExtension()}',
      ),
    );
  }

  Future<SourcedTrack?> _getSourcedTrack(
    Request request,
    String trackId,
  ) async {
    final track =
        playlist.tracks.firstWhere((element) => element.id == trackId);

    final activeSourcedTrack =
        await ref.read(activeTrackSourcesProvider.future);

    final media = audioPlayer.playlist.medias
        .firstWhere((e) => e.uri == request.requestedUri.toString());
    final spotubeMedia =
        media is SpotubeMedia ? media : SpotubeMedia.media(media);
    final sourcedTrack = activeSourcedTrack?.track.id == track.id
        ? activeSourcedTrack?.source
        : await ref.read(
            sourcedTrackProvider(spotubeMedia.track as SpotubeFullTrackObject)
                .future,
          );

    return sourcedTrack;
  }

  Future<SourcedTrack> _resolvePlayableTrack(
    SourcedTrack track,
    String requestedUri,
  ) async {
    _ensurePlaybackRequestRelevant(requestedUri);
    if (track.url != null) return track;

    final notifier = ref.read(sourcedTrackProvider(track.query).notifier);

    _ensurePlaybackRequestRelevant(requestedUri);
    var resolvedTrack = await notifier.refreshStreamingUrl();
    _ensurePlaybackRequestRelevant(requestedUri);
    if (resolvedTrack.url != null) return resolvedTrack;

    if (resolvedTrack.siblings.isEmpty) {
      _ensurePlaybackRequestRelevant(requestedUri);
      resolvedTrack = await notifier.copyWithSibling();
      _ensurePlaybackRequestRelevant(requestedUri);
      if (resolvedTrack.url != null) return resolvedTrack;
    }

    if (resolvedTrack.siblings.isEmpty) {
      throw StateError(
        "No playable source found for ${track.query.name}",
      );
    }

    resolvedTrack = await notifier.swapWithNextSibling();
    if (resolvedTrack.url != null) return resolvedTrack;

    throw StateError(
      "No playable source found for ${track.query.name}",
    );
  }

  Future<dio_lib.Response> streamTrackInformation(
    Request request,
    SourcedTrack track,
  ) async {
    AppLogger.log.i(
      "HEAD request for track: ${track.query.name}\n"
      "Headers: ${request.headers}",
    );

    final trackCacheFile = File(await _getTrackCacheFilePath(track));

    if (await trackCacheFile.exists() && userPreferences.cacheMusic) {
      final fileLength = await trackCacheFile.length();

      return dio_lib.Response(
        statusCode: 200,
        headers: Headers.fromMap({
          "content-type": ["audio/${track.qualityPreset!.name}"],
          "content-length": ["$fileLength"],
          "accept-ranges": ["bytes"],
          "content-range": ["bytes 0-$fileLength/$fileLength"],
        }),
        requestOptions: RequestOptions(path: request.requestedUri.toString()),
      );
    }

    final requestedUri = request.requestedUri.toString();
    final resolvedTrack = await _resolvePlayableTrack(track, requestedUri);
    final url = resolvedTrack.url!;

    final options = Options(
      headers: {
        "user-agent": _randomUserAgent,
        "Cache-Control": "max-age=3600",
        "Connection": "keep-alive",
        "host": Uri.parse(url).host,
      },
      validateStatus: (status) => status! < 400,
    );

    final res = await dio.head(url, options: options);

    return res;
  }

  Future<dio_lib.Response> streamTrack(
    Request request,
    SourcedTrack track,
    Map<String, dynamic> headers,
  ) async {
    AppLogger.log.i(
      "GET request for track: ${track.query.name}\n"
      "Headers: ${request.headers}",
    );

    final requestedUri = request.requestedUri.toString();
    final trackCacheFile = File(await _getTrackCacheFilePath(track));

    if (await trackCacheFile.exists() && userPreferences.cacheMusic) {
      final bytes = await trackCacheFile.readAsBytes();
      final cachedFileLength = bytes.length;

      return dio_lib.Response<Uint8List>(
        statusCode: 200,
        headers: Headers.fromMap({
          "content-type": ["audio/${track.qualityPreset!.name}"],
          "content-length": ["${cachedFileLength - 1}"],
          "accept-ranges": ["bytes"],
          "content-range": [
            "bytes 0-${cachedFileLength - 1}/$cachedFileLength"
          ],
          "connection": ["close"],
        }),
        requestOptions: RequestOptions(path: request.requestedUri.toString()),
        data: bytes,
      );
    }

    var activeTrack = await _resolvePlayableTrack(track, requestedUri);
    String url = activeTrack.url!;

    Options optionsFor(String sourceUrl) => Options(
          headers: {
            ...headers,
            "user-agent": _randomUserAgent,
            "Cache-Control": "max-age=3600",
            "Connection": "keep-alive",
            "host": Uri.parse(sourceUrl).host,
          },
          responseType: ResponseType.stream,
          validateStatus: (status) => status! < 400,
        );

    Future<dio_lib.Response<ResponseBody>> fetchStream(String sourceUrl) {
      return dio.get<ResponseBody>(sourceUrl, options: optionsFor(sourceUrl));
    }

    dio_lib.Response<ResponseBody> res;
    try {
      res = await fetchStream(url);
    } catch (e, stack) {
      AppLogger.reportError(e, stack);

      final notifier =
          ref.read(sourcedTrackProvider(activeTrack.query).notifier);
      _ensurePlaybackRequestRelevant(requestedUri);
      activeTrack = await notifier.refreshStreamingUrl();
      _ensurePlaybackRequestRelevant(requestedUri);
      if (activeTrack.url == null && activeTrack.siblings.isEmpty) {
        _ensurePlaybackRequestRelevant(requestedUri);
        activeTrack = await notifier.copyWithSibling();
        _ensurePlaybackRequestRelevant(requestedUri);
      }
      if (activeTrack.url == null && activeTrack.siblings.isNotEmpty) {
        _ensurePlaybackRequestRelevant(requestedUri);
        activeTrack = await notifier.swapWithNextSibling();
        _ensurePlaybackRequestRelevant(requestedUri);
      }
      url = activeTrack.url!;

      try {
        res = await fetchStream(url);
      } catch (refreshError, refreshStack) {
        AppLogger.reportError(refreshError, refreshStack);
        if (activeTrack.siblings.isEmpty) {
          _ensurePlaybackRequestRelevant(requestedUri);
          activeTrack = await notifier.copyWithSibling();
          _ensurePlaybackRequestRelevant(requestedUri);
        }
        if (activeTrack.siblings.isEmpty) rethrow;

        _ensurePlaybackRequestRelevant(requestedUri);
        activeTrack = await notifier.swapWithNextSibling();
        _ensurePlaybackRequestRelevant(requestedUri);
        url = activeTrack.url!;
        res = await fetchStream(url);
      }
    }

    // Redirect to m3u8 link directly as it handles range requests internally
    if (res.headers.value("content-type") == "application/vnd.apple.mpegurl") {
      return dio_lib.Response<Uint8List>(
        statusCode: 301,
        statusMessage: "M3U8 Redirect",
        headers: Headers.fromMap({
          "location": [url],
          "content-type": ["application/vnd.apple.mpegurl"],
        }),
        requestOptions: RequestOptions(path: request.requestedUri.toString()),
        isRedirect: true,
      );
    }

    AppLogger.log.i(
      "Response for track: ${track.query.name}\n"
      "Status Code: ${res.statusCode}\n"
      "Headers: ${res.headers.map}",
    );

    if (!userPreferences.cacheMusic) {
      return res;
    }

    final resStream = res.data!.stream.asBroadcastStream();

    final trackPartialCacheFile = File("${trackCacheFile.path}.part");
    if (!await trackPartialCacheFile.exists()) {
      await trackPartialCacheFile.create(recursive: true);
    }

    // Write the stream to the file based on the range
    final partialCacheFileSink =
        trackPartialCacheFile.openWrite(mode: FileMode.writeOnlyAppend);
    final contentRange = res.headers.value("content-range") != null
        ? ContentRangeHeader.parse(res.headers.value("content-range") ?? "")
        : ContentRangeHeader(0, 0, 0);

    resStream.listen(
      (data) {
        partialCacheFileSink.add(data);
      },
      onError: (e, stack) {
        partialCacheFileSink.close();
      },
      onDone: () async {
        await partialCacheFileSink.close();

        final fileLength = await trackPartialCacheFile.length();
        if (fileLength != contentRange.total) return;

        await trackPartialCacheFile.rename(trackCacheFile.path);

        if (track.qualityPreset!.getFileExtension() == "weba") return;

        final imageBytes = await ServiceUtils.downloadImage(
          track.query.album.images.asUrlString(
            placeholder: ImagePlaceholder.albumArt,
            index: 1,
          ),
        );

        await MetadataGod.writeMetadata(
          file: trackCacheFile.path,
          metadata: track.query.toMetadata(
            imageBytes: imageBytes,
            fileLength: fileLength,
          ),
        ).catchError((e, stackTrace) {
          AppLogger.reportError(e, stackTrace);
        });
      },
      cancelOnError: true,
    );

    res.data?.stream =
        resStream; // To avoid Stream has been already listened to exception
    return res;
  }

  /// @head('/stream/<trackId>')
  Future<Response> headStreamTrackId(Request request, String trackId) async {
    try {
      final sourcedTrack = await _getSourcedTrack(request, trackId);

      if (sourcedTrack == null) {
        return Response.notFound("Track not found in the current queue");
      }

      final res = await streamTrackInformation(
        request,
        sourcedTrack,
      );

      return Response(
        res.statusCode!,
        headers: res.headers.map,
      );
    } on StateError catch (e) {
      if (e.message.toString().startsWith("Stale playback request:")) {
        return Response(410);
      }
      rethrow;
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      return Response.internalServerError();
    }
  }

  /// @get('/stream/<trackId>')
  Future<Response> getStreamTrackId(Request request, String trackId) async {
    try {
      final sourcedTrack = await _getSourcedTrack(request, trackId);

      if (sourcedTrack == null) {
        return Response.notFound("Track not found in the current queue");
      }

      final res = await streamTrack(
        request,
        sourcedTrack,
        request.headers,
      );

      if (res.data is ResponseBody) {
        return Response(
          res.statusCode!,
          body: (res.data as ResponseBody).stream,
          headers: res.headers.map,
        );
      }

      return Response(
        res.statusCode!,
        body: res.data,
        headers: res.headers.map,
      );
    } on StateError catch (e) {
      if (e.message.toString().startsWith("Stale playback request:")) {
        return Response(410);
      }
      rethrow;
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      return Response.internalServerError();
    }
  }

  /// @get('/playback/toggle-playback')
  Future<Response> togglePlayback(Request request) async {
    audioPlayer.isPlaying
        ? await audioPlayer.pause()
        : await audioPlayer.resume();

    return Response.ok("Playback toggled");
  }

  /// @get('/playback/previous')
  Future<Response> previousTrack(Request request) async {
    await audioPlayer.skipToPrevious();
    return Response.ok("Previous track");
  }

  /// @get('/playback/next')
  Future<Response> nextTrack(Request request) async {
    await audioPlayer.skipToNext();
    return Response.ok("Next track");
  }
}

final serverPlaybackRoutesProvider =
    Provider((ref) => ServerPlaybackRoutes(ref));
