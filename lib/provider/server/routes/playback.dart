import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:collection/collection.dart';
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

import 'package:spotube/provider/server/sourced_track_provider.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/youtube_engine/android_yt_dlp_engine.dart';
import 'package:spotube/utils/platform.dart';
import 'package:spotube/services/logger/playback_start_trace.dart';
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
  static const _streamFailureCooldown = Duration(seconds: 8);
  final Ref ref;
  UserPreferences get userPreferences => ref.read(userPreferencesProvider);
  AudioPlayerState get playlist => ref.read(audioPlayerProvider);
  final Dio dio;
  final Map<String, DateTime> _recentStreamFailures = {};
  final Map<String, CancelToken> _activeUpstreamRequests = {};
  final Map<String, int> _streamRequestCounts = {};
  final Map<String, int> _upstreamAttemptCounts = {};
  final Map<String, Future<SourcedTrack?>> _inFlightTrackLookups = {};

  ServerPlaybackRoutes(this.ref) : dio = Dio();

  String _memoryLabel() =>
      "${(ProcessInfo.currentRss / (1024 * 1024)).toStringAsFixed(1)}MB";

  void _trace(String message) {
    if (!kReleaseMode) return;
    AppLogger.trace("[playback] $message | rss=${_memoryLabel()}");
  }

  void _critical(String message) {
    AppLogger.criticalTrace("[playback] $message | rss=${_memoryLabel()}");
  }

  bool _isPlaybackRequestRelevant(String requestedUri) {
    return requestedUri == audioPlayer.currentSource ||
        requestedUri == audioPlayer.nextSource;
  }

  void _ensurePlaybackRequestRelevant(String requestedUri) {
    if (_isPlaybackRequestRelevant(requestedUri)) return;

    throw StateError("Stale playback request: $requestedUri");
  }

  String _streamFailureKey(SourcedTrack track) => track.query.id;

  bool _isInStreamFailureCooldown(SourcedTrack track) {
    final lastFailureAt = _recentStreamFailures[_streamFailureKey(track)];
    if (lastFailureAt == null) return false;

    final stillCoolingDown =
        DateTime.now().difference(lastFailureAt) < _streamFailureCooldown;
    if (!stillCoolingDown) {
      _recentStreamFailures.remove(_streamFailureKey(track));
    }
    return stillCoolingDown;
  }

  void _markStreamFailure(SourcedTrack track) {
    _recentStreamFailures[_streamFailureKey(track)] = DateTime.now();
  }

  void _clearStreamFailure(SourcedTrack track) {
    _recentStreamFailures.remove(_streamFailureKey(track));
  }

  CancelToken _replaceUpstreamRequest(String requestedUri) {
    final replaced = _activeUpstreamRequests.remove(requestedUri);
    if (replaced != null) {
      _trace(
        "cancel previous upstream uri=$requestedUri active=${_activeUpstreamRequests.length}",
      );
      replaced.cancel("Superseded");
    }
    final token = CancelToken();
    _activeUpstreamRequests[requestedUri] = token;
    _trace(
      "register upstream uri=$requestedUri active=${_activeUpstreamRequests.length}",
    );
    return token;
  }

  void _clearUpstreamRequest(String requestedUri, CancelToken token) {
    final activeToken = _activeUpstreamRequests[requestedUri];
    if (identical(activeToken, token)) {
      _activeUpstreamRequests.remove(requestedUri);
      _trace(
        "clear upstream uri=$requestedUri active=${_activeUpstreamRequests.length}",
      );
    }
  }

  Stream<Uint8List> _attachUpstreamCleanup(
    String requestedUri,
    CancelToken token,
    Stream<Uint8List> source,
  ) {
    late final StreamSubscription<Uint8List> subscription;
    late final StreamController<Uint8List> controller;
    controller = StreamController<Uint8List>(
      onListen: () {
        _trace("listen upstream stream uri=$requestedUri");
        _critical("listen upstream stream uri=$requestedUri");
        subscription = source.listen(
          controller.add,
          onError: (error, stackTrace) {
            _clearUpstreamRequest(requestedUri, token);
            _trace("error upstream stream uri=$requestedUri error=$error");
            _critical("error upstream stream uri=$requestedUri error=$error");
            controller.addError(error, stackTrace);
          },
          onDone: () {
            _clearUpstreamRequest(requestedUri, token);
            _trace("done upstream stream uri=$requestedUri");
            _critical("done upstream stream uri=$requestedUri");
            controller.close();
          },
          cancelOnError: true,
        );
      },
      onPause: () => subscription.pause(),
      onResume: () => subscription.resume(),
      onCancel: () async {
        await subscription.cancel();
        _trace("cancel upstream stream uri=$requestedUri");
        _critical("cancel upstream stream uri=$requestedUri");
        _clearUpstreamRequest(requestedUri, token);
      },
    );

    return controller.stream;
  }

  RangeHeader? _getRequestedRange(Request request) {
    final rawRange = request.headers["range"];
    if (rawRange == null || rawRange.isEmpty) return null;

    try {
      return RangeHeader.parse(rawRange);
    } catch (error, stackTrace) {
      AppLogger.reportError(error, stackTrace);
      return null;
    }
  }

  ({int start, int end, int total}) _resolveByteRange(
    int totalLength,
    RangeHeader? requestedRange,
  ) {
    final total = max(totalLength, 0);
    if (total == 0) {
      return (start: 0, end: 0, total: 0);
    }

    final start =
        requestedRange == null ? 0 : requestedRange.start.clamp(0, total - 1);
    final end = requestedRange?.end == null
        ? total - 1
        : requestedRange!.end!.clamp(start, total - 1);

    return (start: start, end: end, total: total);
  }

  Map<String, List<String>> _cachedTrackHeaders({
    required SourcedTrack track,
    required int totalLength,
    required int start,
    required int end,
    required bool isPartial,
  }) {
    final contentLength = totalLength == 0 ? 0 : (end - start + 1);

    return {
      "content-type": ["audio/${track.qualityPreset!.name}"],
      "content-length": ["$contentLength"],
      "accept-ranges": ["bytes"],
      "connection": ["close"],
      if (isPartial && totalLength > 0)
        "content-range": ["bytes $start-$end/$totalLength"],
    };
  }

  bool _shouldBypassStreamingProxy(SourcedTrack track) => kIsDesktop;

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
    final active = _inFlightTrackLookups[trackId];
    if (active != null) {
      return active;
    }

    final future = _getSourcedTrackInternal(request, trackId);
    _inFlightTrackLookups[trackId] = future;
    try {
      return await future;
    } finally {
      final current = _inFlightTrackLookups[trackId];
      if (identical(current, future)) {
        _inFlightTrackLookups.remove(trackId);
      }
    }
  }

  Future<SourcedTrack?> _getSourcedTrackInternal(
    Request request,
    String trackId,
  ) async {
    final track =
        playlist.tracks.firstWhere((element) => element.id == trackId);

    if (track is SpotubeLocalTrackObject) {
      return null;
    }

    final fullTrack = track as SpotubeFullTrackObject;
    _critical(
      "direct fetch sourced track uri=${request.requestedUri} track=${fullTrack.id}",
    );
    final sourcedTrack = await SourcedTrack.fetchFromTrack(
      query: fullTrack,
      ref: ref,
    );
    _critical(
      "direct fetch sourced track done uri=${request.requestedUri} track=${fullTrack.id}",
    );
    return sourcedTrack;
  }

  Future<SourcedTrack> _resolvePlayableTrack(
    SourcedTrack track,
    String requestedUri,
  ) async {
    PlaybackStartTrace.markTrack(
      track.query.id,
      'server.resolve_playable.start',
      data: {'requestedUri': requestedUri},
    );
    _ensurePlaybackRequestRelevant(requestedUri);
    if (track.url != null) {
      PlaybackStartTrace.markTrack(
        track.query.id,
        'server.resolve_playable.short_circuit',
      );
      return track;
    }

    final notifier = ref.read(sourcedTrackProvider(track.query).notifier);

    _ensurePlaybackRequestRelevant(requestedUri);
    var resolvedTrack = await notifier.refreshStreamingUrl();
    _ensurePlaybackRequestRelevant(requestedUri);
    if (resolvedTrack.url != null) {
      PlaybackStartTrace.markTrack(track.query.id, 'server.resolve_playable.done');
      return resolvedTrack;
    }

    if (resolvedTrack.siblings.isEmpty) {
      _ensurePlaybackRequestRelevant(requestedUri);
      resolvedTrack = await notifier.copyWithSibling();
      _ensurePlaybackRequestRelevant(requestedUri);
      if (resolvedTrack.url != null) {
        PlaybackStartTrace.markTrack(track.query.id, 'server.resolve_playable.done');
        return resolvedTrack;
      }
    }

    final triedTrackIds = <String>{resolvedTrack.info.id};
    while (resolvedTrack.url == null) {
      final nextSibling = resolvedTrack.siblings.firstWhereOrNull(
        (sibling) => !triedTrackIds.contains(sibling.id),
      );
      if (nextSibling == null) {
        break;
      }
      triedTrackIds.add(nextSibling.id);
      _ensurePlaybackRequestRelevant(requestedUri);
      PlaybackStartTrace.markTrack(
        track.query.id,
        'server.resolve_playable.try_sibling',
        data: {'sourceId': nextSibling.id},
      );
      resolvedTrack = await notifier.swapWithSibling(nextSibling);
      _ensurePlaybackRequestRelevant(requestedUri);
      if (resolvedTrack.url != null) {
        PlaybackStartTrace.markTrack(track.query.id, 'server.resolve_playable.done');
        return resolvedTrack;
      }
    }

    PlaybackStartTrace.failTrack(
      track.query.id,
      'server.resolve_playable.failed_no_source',
    );
    throw StateError("No playable source found for ${track.query.name}");
  }

  Future<dio_lib.Response> streamTrackInformation(
    Request request,
    SourcedTrack track,
  ) async {
    final requestedUri = request.requestedUri.toString();
    final requestCount = (_streamRequestCounts[requestedUri] =
        (_streamRequestCounts[requestedUri] ?? 0) + 1);
    _trace(
      "HEAD uri=$requestedUri track=${track.query.id} count=$requestCount queueIndex=${playlist.currentIndex} queueSize=${playlist.tracks.length} activeSource=${audioPlayer.currentSource}",
    );

    if (userPreferences.cacheMusic) {
      final trackCacheFile = File(await _getTrackCacheFilePath(track));
      if (await trackCacheFile.exists()) {
        final fileLength = await trackCacheFile.length();
        final requestedRange = _getRequestedRange(request);
        final resolvedRange = _resolveByteRange(fileLength, requestedRange);
        final isPartial = requestedRange != null;

        return dio_lib.Response(
          statusCode: isPartial ? 206 : 200,
          headers: Headers.fromMap(
            _cachedTrackHeaders(
              track: track,
              totalLength: fileLength,
              start: resolvedRange.start,
              end: resolvedRange.end,
              isPartial: isPartial,
            ),
          ),
          requestOptions: RequestOptions(path: request.requestedUri.toString()),
        );
      }
    }

    final resolvedTrack = await _resolvePlayableTrack(track, requestedUri);
    final url = resolvedTrack.url!;

    if (_shouldBypassStreamingProxy(track)) {
      return dio_lib.Response(
        statusCode: 307,
        statusMessage: "Temporary Redirect",
        headers: Headers.fromMap({
          "location": [url],
          "connection": ["close"],
        }),
        requestOptions: RequestOptions(path: request.requestedUri.toString()),
        isRedirect: true,
      );
    }

    final options = Options(
      headers: {
        "user-agent": _randomUserAgent,
        "Cache-Control": "max-age=3600",
        "Connection": "close",
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
    PlaybackStartTrace.markTrack(
      track.query.id,
      'server.stream_route.start',
      data: {'uri': request.requestedUri.toString()},
    );
    final requestedUri = request.requestedUri.toString();
    final requestCount = (_streamRequestCounts[requestedUri] =
        (_streamRequestCounts[requestedUri] ?? 0) + 1);
    _trace(
      "GET uri=$requestedUri track=${track.query.id} count=$requestCount queueIndex=${playlist.currentIndex} queueSize=${playlist.tracks.length} activeSource=${audioPlayer.currentSource} nextSource=${audioPlayer.nextSource}",
    );
    _critical(
      "GET uri=$requestedUri track=${track.query.id} count=$requestCount queueIndex=${playlist.currentIndex} queueSize=${playlist.tracks.length}",
    );
    File? trackCacheFile;

    if (userPreferences.cacheMusic) {
      trackCacheFile = File(await _getTrackCacheFilePath(track));
      if (await trackCacheFile.exists()) {
        PlaybackStartTrace.markTrack(track.query.id, 'server.stream_route.cache_hit');
        final cachedFileLength = await trackCacheFile.length();
        final requestedRange = _getRequestedRange(request);
        final resolvedRange = _resolveByteRange(
          cachedFileLength,
          requestedRange,
        );
        final isPartial = requestedRange != null;

        _trace(
          "serve cached uri=$requestedUri track=${track.query.id} partial=$isPartial start=${resolvedRange.start} end=${resolvedRange.end} total=${resolvedRange.total}",
        );
        return dio_lib.Response<Stream<List<int>>>(
          statusCode: isPartial ? 206 : 200,
          headers: Headers.fromMap(
            _cachedTrackHeaders(
              track: track,
              totalLength: cachedFileLength,
              start: resolvedRange.start,
              end: resolvedRange.end,
              isPartial: isPartial,
            ),
          ),
          requestOptions: RequestOptions(path: request.requestedUri.toString()),
          data: trackCacheFile.openRead(
            resolvedRange.start,
            resolvedRange.total == 0 ? 0 : resolvedRange.end + 1,
          ),
        );
      }
    }

    if (_isInStreamFailureCooldown(track)) {
      _trace("cooldown hit uri=$requestedUri track=${track.query.id}");
      throw StateError("Recent playback failure: ${track.query.id}");
    }

    SourcedTrack activeTrack;
    try {
      activeTrack = await _resolvePlayableTrack(track, requestedUri);
    } catch (e, stack) {
      PlaybackStartTrace.failTrack(
        track.query.id,
        'server.stream_route.resolve_failed',
        data: {'error': e.toString()},
      );
      _markStreamFailure(track);
      AppLogger.reportError(e, stack);
      rethrow;
    }
    _critical(
      "track resolved uri=$requestedUri track=${activeTrack.query.id} hasUrl=${activeTrack.url != null}",
    );
    _critical(
      "about to read url uri=$requestedUri track=${activeTrack.query.id}",
    );
    String url = activeTrack.url!;
    _critical(
      "url read uri=$requestedUri track=${activeTrack.query.id} host=${Uri.parse(url).host}",
    );

    if (_shouldBypassStreamingProxy(activeTrack)) {
      PlaybackStartTrace.markTrack(
        activeTrack.query.id,
        'server.stream_route.redirect_direct',
      );
      _critical(
        "redirect direct uri=$requestedUri track=${activeTrack.query.id} host=${Uri.parse(url).host}",
      );
      return dio_lib.Response(
        statusCode: 307,
        statusMessage: "Temporary Redirect",
        headers: Headers.fromMap({
          "location": [url],
          "connection": ["close"],
        }),
        requestOptions: RequestOptions(path: request.requestedUri.toString()),
        isRedirect: true,
      );
    }

    final cancelToken = _replaceUpstreamRequest(requestedUri);
    _critical(
      "register upstream uri=$requestedUri track=${activeTrack.query.id} active=${_activeUpstreamRequests.length}",
    );

    Options optionsFor(String sourceUrl) => Options(
          headers: {
            ...headers,
            ...?_ytDlpHeaders(sourceUrl),
            "referer": "https://www.youtube.com/",
            "host": Uri.parse(sourceUrl).host,
          },
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
        );

    Map<String, String>? _ytDlpHeaders(String url) {
      try {
        return AndroidYtDlpEngine.headersForUrl(url);
      } catch (_) {
        return null;
      }
    }

    Future<dio_lib.Response<ResponseBody>> fetchStream(String sourceUrl) {
      final attemptCount = (_upstreamAttemptCounts[requestedUri] =
          (_upstreamAttemptCounts[requestedUri] ?? 0) + 1);
      _trace(
        "start upstream uri=$requestedUri track=${activeTrack.query.id} attempt=$attemptCount host=${Uri.parse(sourceUrl).host}",
      );
      _critical(
        "start upstream uri=$requestedUri track=${activeTrack.query.id} attempt=$attemptCount host=${Uri.parse(sourceUrl).host}",
      );
      return dio.get<ResponseBody>(
        sourceUrl,
        options: optionsFor(sourceUrl),
        cancelToken: cancelToken,
      );
    }

    dio_lib.Response<ResponseBody> res;
    try {
      PlaybackStartTrace.markTrack(
        activeTrack.query.id,
        'server.upstream_fetch.start',
        data: {'host': Uri.parse(url).host},
      );
      res = await fetchStream(url);
      PlaybackStartTrace.markTrack(
        activeTrack.query.id,
        'server.upstream_fetch.connected',
        data: {'statusCode': res.statusCode ?? 0},
      );
    } catch (e, stack) {
      if (e is! DioException || !CancelToken.isCancel(e)) {
        AppLogger.reportError(e, stack);
      }

      final notifier =
          ref.read(sourcedTrackProvider(activeTrack.query).notifier);
      _ensurePlaybackRequestRelevant(requestedUri);
      try {
        activeTrack = await _resolvePlayableTrack(
          await notifier.refreshStreamingUrl(),
          requestedUri,
        );
      } catch (resolveError, resolveStack) {
        _markStreamFailure(activeTrack);
        AppLogger.reportError(resolveError, resolveStack);
        rethrow;
      }
      url = activeTrack.url!;
      try {
        PlaybackStartTrace.markTrack(
          activeTrack.query.id,
          'server.upstream_fetch.retry_start',
          data: {'host': Uri.parse(url).host},
        );
        res = await fetchStream(url);
        PlaybackStartTrace.markTrack(
          activeTrack.query.id,
          'server.upstream_fetch.retry_connected',
          data: {'statusCode': res.statusCode ?? 0},
        );
      } catch (retryError, retryStack) {
        PlaybackStartTrace.failTrack(
          activeTrack.query.id,
          'server.upstream_fetch.retry_failed',
          data: {'error': retryError.toString()},
        );
        if (retryError is! DioException || !CancelToken.isCancel(retryError)) {
          _markStreamFailure(activeTrack);
          AppLogger.reportError(retryError, retryStack);
        }
        rethrow;
      }
    }

    if (res.statusCode != 200) {
      _trace(
        "upstream non-200 uri=$requestedUri track=${activeTrack.query.id} status=${res.statusCode}",
      );
      final notifier = ref.read(sourcedTrackProvider(activeTrack.query).notifier);
      _ensurePlaybackRequestRelevant(requestedUri);
      try {
        activeTrack = await _resolvePlayableTrack(
          await notifier.refreshStreamingUrl(),
          requestedUri,
        );
      } catch (resolveError, resolveStack) {
        _markStreamFailure(activeTrack);
        AppLogger.reportError(resolveError, resolveStack);
        rethrow;
      }
      url = activeTrack.url!;
      try {
        res = await fetchStream(url);
      } catch (retryError, retryStack) {
        _markStreamFailure(activeTrack);
        AppLogger.reportError(retryError, retryStack);
        rethrow;
      }
    }

    _clearStreamFailure(activeTrack);

    _trace(
      "upstream response uri=$requestedUri track=${activeTrack.query.id} status=${res.statusCode} contentType=${res.headers.value('content-type')}",
    );
    _critical(
      "upstream response uri=$requestedUri track=${activeTrack.query.id} status=${res.statusCode} contentType=${res.headers.value('content-type')}",
    );

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

    if (!_shouldBypassStreamingProxy(activeTrack) &&
        !userPreferences.cacheMusic) {
      res.data?.stream = _attachUpstreamCleanup(
        requestedUri,
        cancelToken,
        res.data!.stream,
      );
      _critical(
        "proxy passthrough uri=$requestedUri track=${activeTrack.query.id}",
      );
      return res;
    }

    final upstream = _attachUpstreamCleanup(
      requestedUri,
      cancelToken,
      res.data!.stream,
    );

    final effectiveTrackCacheFile = trackCacheFile;
    if (effectiveTrackCacheFile == null) {
      res.data?.stream = upstream;
      return res;
    }

    final trackPartialCacheFile = File("${effectiveTrackCacheFile.path}.part");
    if (!await trackPartialCacheFile.exists()) {
      await trackPartialCacheFile.create(recursive: true);
    }

    final partialCacheFileSink =
        trackPartialCacheFile.openWrite(mode: FileMode.writeOnlyAppend);
    final contentRange = res.headers.value("content-range") != null
        ? ContentRangeHeader.parse(res.headers.value("content-range") ?? "")
        : ContentRangeHeader(0, 0, 0);

    res.data?.stream = _streamWithCachePassthrough(
      upstream,
      partialCacheFileSink,
      onComplete: () async {
        final fileLength = await trackPartialCacheFile.length();
        if (fileLength != contentRange.total) {
          _trace(
            "cache incomplete uri=$requestedUri track=${track.query.id} length=$fileLength expected=${contentRange.total}",
          );
          return;
        }

        _trace("cache finalize uri=$requestedUri track=${track.query.id}");
        await trackPartialCacheFile.rename(effectiveTrackCacheFile.path);

        if (track.qualityPreset!.getFileExtension() == "weba") return;

        final imageBytes = await ServiceUtils.downloadImage(
          track.query.album.images.asUrlString(
            placeholder: ImagePlaceholder.albumArt,
            index: 1,
          ),
        );

        await MetadataGod.writeMetadata(
          file: effectiveTrackCacheFile.path,
          metadata: track.query.toMetadata(
            imageBytes: imageBytes,
            fileLength: fileLength,
          ),
        ).catchError((e, stackTrace) {
          AppLogger.reportError(e, stackTrace);
        });
      },
      onError: (e) {
        _trace(
          "cache write error uri=$requestedUri track=${track.query.id} error=$e",
        );
      },
    );
    return res;
  }

  Stream<Uint8List> _streamWithCachePassthrough(
    Stream<Uint8List> source,
    IOSink cacheSink, {
    required Future<void> Function() onComplete,
    required void Function(Object error) onError,
  }) async* {
    try {
      await for (final chunk in source) {
        cacheSink.add(chunk);
        yield chunk;
      }
      await cacheSink.close();
      await onComplete();
    } catch (error, stackTrace) {
      onError(error);
      await cacheSink.close();
      Error.throwWithStackTrace(error, stackTrace);
    }
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
      if (e.message.toString().startsWith("Recent playback failure:")) {
        return Response.internalServerError(
          body: "Track is temporarily unavailable",
        );
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
      _critical(
        "route entered uri=${request.requestedUri} track=$trackId",
      );
      _critical(
        "about to get sourced track uri=${request.requestedUri} track=$trackId",
      );
      final sourcedTrack = await _getSourcedTrack(request, trackId);
      _critical(
        "got sourced track uri=${request.requestedUri} track=$trackId null=${sourcedTrack == null}",
      );

      if (sourcedTrack == null) {
        return Response.notFound("Track not found in the current queue");
      }

      _critical(
        "about to stream track uri=${request.requestedUri} track=$trackId",
      );
      final res = await streamTrack(
        request,
        sourcedTrack,
        request.headers,
      );
      _critical(
        "stream track returned uri=${request.requestedUri} track=$trackId status=${res.statusCode}",
      );

      if (res.data is ResponseBody) {
        return Response(
          res.statusCode!,
          body: (res.data as ResponseBody).stream,
          headers: res.headers.map,
        );
      }

      if (res.data is Stream<List<int>>) {
        return Response(
          res.statusCode!,
          body: res.data as Stream<List<int>>,
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
