import 'dart:io';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/youtube_engine/android_yt_dlp_engine.dart';

extension ChunkDownloaderDioExtension on Dio {
  /// True for YouTube CDN stream URLs (Flow parity): googlevideo.com hosts OR
  /// youtube.com/videoplayback — YouTube may serve either depending on client.
  bool _isYouTubeStreamUrl(String url) {
    try {
      final host = Uri.parse(url).host;
      return host.contains('googlevideo.com') ||
          (host.contains('youtube.com') && url.contains('videoplayback'));
    } catch (_) {
      return false;
    }
  }

  /// Matching User-Agent for the `c=` query param of a googlevideo URL (the
  /// client that minted it). Flow: "a mismatch is a known cause of mid-stream
  /// 403s on googlevideo CDNs."
  String _gvUserAgent(String url) {
    final c = Uri.tryParse(url)?.queryParameters['c']?.toUpperCase();
    switch (c) {
      case 'IOS':
        return 'com.google.ios.youtube/21.03.3 (iPad7,6; U; CPU iPadOS 17_7_10 like Mac OS X; en-US)';
      case 'ANDROID' || 'ANDROID_CREATOR':
        return 'com.google.android.youtube/21.03.38 (Linux; U; Android 14) gzip';
      case 'ANDROID_VR':
        return 'com.google.android.apps.youtube.vr.oculus/1.61.48 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/132.0.6808.3)';
      default:
        return 'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip';
    }
  }

  /// googlevideo serves byte ranges via the `range=X-Y` QUERY PARAM (Flow's
  /// approach), not the HTTP `Range` header — non-zero HTTP ranges 403 without
  /// a logged-in session in some regions (gcr=eg), while query-param ranges
  /// are served to anonymous clients. Strip the embedded `range=0-N` cap and
  /// request the whole file (`range=0-<clen-1>`), like Flow's downloader.
  String _rewriteGvFullUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final params = <String, dynamic>{};
      uri.queryParametersAll.forEach((k, v) {
        if (k == 'range') return;
        params[k] = v.length == 1 ? v.first : v;
      });
      final clen = int.tryParse(uri.queryParameters['clen'] ?? '');
      if (clen != null && clen > 0) {
        params['range'] = '0-${clen - 1}';
      }
      return uri.replace(queryParameters: params).toString();
    } catch (_) {
      return url;
    }
  }

  Map<String, dynamic> _gvDownloadHeaders(String url) {
    // Prefer the EXACT headers stored for this URL during stream resolution
    // (the client UA that minted it + visitor cookie) — a UA version mismatch
    // is a known cause of audio-only 403s on googlevideo.
    final h = <String, dynamic>{};
    try {
      final stored = AndroidYtDlpEngine.headersForUrl(url);
      if (stored != null && stored.isNotEmpty) {
        h.addAll(stored);
      }
    } catch (_) {}
    h.putIfAbsent('User-Agent', () => _gvUserAgent(url));
    h['Origin'] = 'https://www.youtube.com';
    h['Referer'] = 'https://www.youtube.com/';
    h['Accept'] = '*/*';
    h['Accept-Encoding'] = 'identity';
    return h;
  }

  /// Download a googlevideo stream with the same HTTP stack the streaming
  /// proxy uses (http.Client + `range=X-Y` query param + matching UA), which
  /// is proven to work in every region. dio's own `download`/`Range`-header
  /// chunk path can 403 where http.Client succeeds — the proxy hit exactly
  /// this and switched to http.Client.
  Future<Response> _downloadGooglevideo(
    String urlPath,
    dynamic savePath, {
    ProgressCallback? onReceiveProgress,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    bool deleteOnError = true,
  }) async {
    var finalUri = Uri.parse(_rewriteGvFullUrl(urlPath));
    if (queryParameters != null && queryParameters.isNotEmpty) {
      final qps = <String, dynamic>{};
      finalUri.queryParametersAll.forEach((k, v) {
        qps[k] = v.length == 1 ? v.first : v;
      });
      queryParameters.forEach((k, v) => qps[k] = '$v');
      finalUri = finalUri.replace(queryParameters: qps);
    }

    final targetFile = File(savePath.toString());
    final partFile = File('${targetFile.path}.part');
    final req = http.Request('GET', finalUri);
    _gvDownloadHeaders(urlPath).forEach((k, v) => req.headers[k] = v);

    final client = http.Client();
    try {
      final resp = await client.send(req).timeout(const Duration(minutes: 5));
      AppLogger.log.i(
          "[chunkdl] gv host=${finalUri.host} status=${resp.statusCode} len=${resp.headers['content-length']} c=${finalUri.queryParameters['c']} url=$finalUri");
      if (resp.statusCode != 200) {
        throw DioException.badResponse(
          statusCode: resp.statusCode,
          requestOptions: RequestOptions(path: urlPath),
          response: Response(
            requestOptions: RequestOptions(path: urlPath),
            statusCode: resp.statusCode,
          ),
        );
      }

      final total = int.tryParse(resp.headers['content-length'] ?? '') ?? 0;
      if (await partFile.exists()) await partFile.delete();
      final sink = partFile.openWrite();
      var downloaded = 0;
      var cancelled = false;
      try {
        await for (final chunk in resp.stream) {
          if (cancelToken?.isCancelled == true) {
            cancelled = true;
            break;
          }
          sink.add(chunk);
          downloaded += chunk.length;
          onReceiveProgress?.call(downloaded, total);
        }
      } finally {
        await sink.close();
      }

      if (cancelled) {
        if (deleteOnError && await partFile.exists()) await partFile.delete();
        throw DioException(
          requestOptions: RequestOptions(path: urlPath),
          type: DioExceptionType.cancel,
          error: 'Download cancelled',
        );
      }

      if (await targetFile.exists()) await targetFile.delete();
      await partFile.rename(targetFile.path);

      return Response(
        requestOptions: RequestOptions(path: urlPath),
        data: targetFile,
        statusCode: 200,
        statusMessage: 'OK',
      );
    } finally {
      client.close();
    }
  }

  Future<Response> chunkDownload(
    String urlPath,
    dynamic savePath, {
    ProgressCallback? onReceiveProgress,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    bool deleteOnError = true,
    FileAccessMode fileAccessMode = FileAccessMode.write,
    String lengthHeader = Headers.contentLengthHeader,
    Object? data,
    Options? options,
    int connections = 4,
  }) async {
    // googlevideo 403s HTTP `Range: bytes=X-Y` requests for non-zero offsets
    // without a logged-in session in some regions (gcr=eg) — the parallel
    // chunk path below would fail (empty file -> metadata RangeError). Mirror
    // the streaming proxy: rewrite the URL to use the `range=X-Y` query param
    // and download sequentially with the client-matching UA + Origin/Referer.
    // Audio files are small, so losing parallel chunks is negligible.
    final isYt = _isYouTubeStreamUrl(urlPath);
    AppLogger.log.i(
        "[chunkdl] start host=${Uri.parse(urlPath).host} isYt=$isYt c=${Uri.parse(urlPath).queryParameters['c']} hasN=${urlPath.contains('n=')} hasPot=${urlPath.contains('pot=')} url=$urlPath");
    if (isYt) {
      return _downloadGooglevideo(
        urlPath,
        savePath,
        onReceiveProgress: onReceiveProgress,
        queryParameters: queryParameters,
        cancelToken: cancelToken,
        deleteOnError: deleteOnError,
      );
    }

    final targetFile = File(savePath.toString());
    final tempRootDir = await getTemporaryDirectory();
    final tempSaveDir = Directory(
      join(
        tempRootDir.path,
        'Spotube',
        '.chunk_dl_${targetFile.uri.pathSegments.last}',
      ),
    );
    if (await tempSaveDir.exists()) await tempSaveDir.delete(recursive: true);
    await tempSaveDir.create(recursive: true);

    try {
      int? totalLength;
      bool supportsRange = false;

      Response? headResp;
      try {
        headResp = await head(
          urlPath,
          queryParameters: queryParameters,
          options: Options(
            headers: {'Range': 'bytes=0-0'},
            followRedirects: true,
          ),
        );
      } catch (_) {
        // Some servers reject HEAD -> ignore
      }

      final lengthStr = headResp?.headers[lengthHeader]?.first;
      if (lengthStr != null) {
        final parsed = int.tryParse(lengthStr);
        if (parsed != null && parsed > 1) {
          totalLength = parsed;
        }
      }

      supportsRange = headResp?.statusCode == 206 ||
          headResp?.headers.value(HttpHeaders.acceptRangesHeader) == 'bytes';

      if (totalLength == null || totalLength <= 1) {
        final resp = await get<ResponseBody>(
          urlPath,
          options: Options(
            responseType: ResponseType.stream,
          ),
          queryParameters: queryParameters,
          cancelToken: cancelToken,
        );

        final len = int.tryParse(resp.headers[lengthHeader]?.first ?? '');
        if (len == null || len <= 1) {
          // can’t safely chunk — fallback
          return download(
            urlPath,
            savePath,
            onReceiveProgress: onReceiveProgress,
            queryParameters: queryParameters,
            cancelToken: cancelToken,
            deleteOnError: deleteOnError,
            options: options,
            data: data,
          );
        }

        totalLength = len;
        supportsRange =
            resp.headers.value(HttpHeaders.acceptRangesHeader)?.toLowerCase() ==
                'bytes';
      }

      if (!supportsRange || connections <= 1) {
        return download(
          urlPath,
          savePath,
          onReceiveProgress: onReceiveProgress,
          queryParameters: queryParameters,
          cancelToken: cancelToken,
          deleteOnError: deleteOnError,
          options: options,
          data: data,
        );
      }

      final chunkSize = (totalLength / connections).ceil();
      int downloaded = 0;

      final partFiles = List.generate(
        connections,
        (i) => File(join(tempSaveDir.path, 'part_$i')),
      );

      final futures = List.generate(connections, (i) async {
        final start = i * chunkSize;
        final end = (i + 1) * chunkSize - 1;
        if (start >= totalLength!) return;

        final resp = await get<ResponseBody>(
          urlPath,
          options: Options(
            responseType: ResponseType.stream,
            headers: {'Range': 'bytes=$start-$end'},
          ),
          queryParameters: queryParameters,
          cancelToken: cancelToken,
        );

        final file = partFiles[i];
        if (await file.exists()) await file.delete();
        await file.create(recursive: true);
        final sink = file.openWrite();

        await for (final chunk in resp.data!.stream) {
          sink.add(chunk);
          downloaded += chunk.length;
          onReceiveProgress?.call(downloaded, totalLength);
        }

        await sink.close();
      });

      await Future.wait(futures);

      final targetSink = targetFile.openWrite();
      for (final f in partFiles) {
        await targetSink.addStream(f.openRead());
      }
      await targetSink.close();

      await tempSaveDir.delete(recursive: true);

      return Response(
        requestOptions: RequestOptions(path: urlPath),
        data: targetFile,
        statusCode: 200,
        statusMessage: 'Chunked download completed ($connections connections)',
      );
    } catch (e) {
      if (deleteOnError) {
        if (await targetFile.exists()) await targetFile.delete();
        if (await tempSaveDir.exists()) {
          await tempSaveDir.delete(recursive: true);
        }
      }
      rethrow;
    }
  }
}
