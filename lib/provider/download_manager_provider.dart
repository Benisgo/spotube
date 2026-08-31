import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:path/path.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' hide join;
import 'package:spotube/collections/routes.dart';
import 'package:spotube/components/dialogs/replace_downloaded_dialog.dart';
import 'package:spotube/extensions/dio.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/audio_source/quality_presets.dart';
import 'package:spotube/provider/local_tracks/local_tracks_provider.dart';
import 'package:spotube/provider/server/sourced_track_provider.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/sourced_track/sourced_track.dart';
import 'package:spotube/utils/service_utils.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

enum DownloadStatus {
  queued,
  downloading,
  completed,
  failed,
  canceled,
}

class DownloadTask {
  final SpotubeFullTrackObject track;
  final DownloadStatus status;
  final CancelToken cancelToken;
  final int? totalSizeBytes;
  final StreamController<int> _downloadedBytesStreamController;

  Stream<int> get downloadedBytesStream =>
      _downloadedBytesStreamController.stream;

  DownloadTask({
    required this.track,
    required this.status,
    required this.cancelToken,
    this.totalSizeBytes,
    StreamController<int>? downloadedBytesStreamController,
  }) : _downloadedBytesStreamController =
            downloadedBytesStreamController ?? StreamController.broadcast();

  DownloadTask copyWith({
    SpotubeFullTrackObject? track,
    DownloadStatus? status,
    CancelToken? cancelToken,
    int? totalSizeBytes,
    StreamController<int>? downloadedBytesStreamController,
  }) {
    return DownloadTask(
      track: track ?? this.track,
      status: status ?? this.status,
      cancelToken: cancelToken ?? this.cancelToken,
      totalSizeBytes: totalSizeBytes ?? this.totalSizeBytes,
      downloadedBytesStreamController:
          downloadedBytesStreamController ?? _downloadedBytesStreamController,
    );
  }
}

class DownloadManagerNotifier extends Notifier<List<DownloadTask>> {
  final Dio dio;
  DownloadManagerNotifier()
      : dio = Dio(),
        super();

  @override
  build() {
    ref.onDispose(() {
      for (final task in state) {
        if (task.status == DownloadStatus.downloading) {
          task.cancelToken.cancel();
        }
        task._downloadedBytesStreamController.close();
      }
      // Shut down the shared HTTP client. Dio.close() releases the underlying
      // HttpClient; without this the manager leaked one client per app run.
      dio.close();
    });

    return [];
  }

  DownloadTask? getTaskByTrackId(String trackId) {
    return state.firstWhereOrNull((element) => element.track.id == trackId);
  }

  void addToQueue(SpotubeFullTrackObject track) {
    if (state.any((element) => element.track.id == track.id)) return;
    state = [
      ...state,
      DownloadTask(
        track: track,
        status: DownloadStatus.queued,
        cancelToken: CancelToken(),
      ),
    ];

    ref.read(sourcedTrackProvider(track));

    _startDownloading(); // No await should be invoked to avoid stuck UI
  }

  void addAllToQueue(List<SpotubeFullTrackObject> tracks) {
    state = [
      ...state,
      ...tracks.map((e) => DownloadTask(
            track: e,
            status: DownloadStatus.queued,
            cancelToken: CancelToken(),
          )),
    ];

    ref.read(sourcedTrackProvider(tracks.first));
    _startDownloading(); // No await should be invoked to avoid stuck UI
  }

  void retry(SpotubeFullTrackObject track) {
    if (state.firstWhereOrNull((e) => e.track.id == track.id)?.status
        case DownloadStatus.canceled || DownloadStatus.failed) {
      _setStatus(track, DownloadStatus.queued);
      _startDownloading(); // No await should be invoked to avoid stuck UI
    }
  }

  void cancel(SpotubeFullTrackObject track) {
    if (state.firstWhereOrNull((e) => e.track.id == track.id)?.status ==
        DownloadStatus.failed) {
      return;
    }
    _setStatus(track, DownloadStatus.canceled);
  }

  void clearAll() {
    for (final task in state) {
      if (task.status == DownloadStatus.downloading) {
        task.cancelToken.cancel();
      }
    }
    state = [];
  }

  void _setStatus(SpotubeFullTrackObject track, DownloadStatus status) {
    state = state.map((e) {
      if (e.track.id == track.id) {
        if ((status == DownloadStatus.canceled) && e.cancelToken.isCancelled) {
          e.cancelToken.cancel();
        }

        return e.copyWith(status: status);
      }
      return e;
    }).toList();
  }

  bool _isShowingDialog = false;

  /// Clients tried for download stream resolution, in priority order (Flow
  /// parity — Flow's FAST_DIRECT_STREAM_CLIENTS starts with ANDROID_VR, then
  /// MOBILE, IOS, ANDROID_CREATOR). No single client's URLs work everywhere:
  /// e.g. ANDROID-minted audio URLs are content-locked (403) in some regions
  /// while ANDROID_VR-minted ones download freely. We try each in order and
  /// use the first whose URL actually downloads.
  // NOTE: YoutubeApiClient.* are `static final` (not const), so this list
  // cannot be `const` — it must be `final`.
  static final List<List<YoutubeApiClient>> _downloadClients = [
    [YoutubeApiClient.androidVr],
    [YoutubeApiClient.mweb],
    [YoutubeApiClient.ios],
    [YoutubeApiClient.android],
    [YoutubeApiClient.tv],
  ];

  static String _clientName(List<YoutubeApiClient> clients) {
    return (clients.first.payload['context']?['client']?['clientName'])
            ?.toString() ??
        'unknown';
  }

  Future<bool> _shouldReplaceFileOnExist(DownloadTask task) async {
    if (rootNavigatorKey.currentContext == null || _isShowingDialog) {
      return false;
    }
    final replaceAll = ref.read(replaceDownloadedFileState);
    if (replaceAll != null) return replaceAll;
    _isShowingDialog = true;
    try {
      return await showDialog<bool>(
            context: rootNavigatorKey.currentContext!,
            builder: (context) => ReplaceDownloadedDialog(
              track: task.track,
            ),
          ) ??
          false;
    } finally {
      _isShowingDialog = false;
    }
  }

  Future<void> _downloadTrack(DownloadTask task) async {
    try {
      _setStatus(task.track, DownloadStatus.downloading);
      final track = await ref.read(sourcedTrackProvider(task.track).future);
      if (task.cancelToken.isCancelled) {
        _setStatus(task.track, DownloadStatus.canceled);
      }
      // The presets notifier loads the plugin's container/quality list
      // asynchronously — on the very first download it may still be empty,
      // which used to crash with a RangeError. Wait for it to populate.
      final presetsProvider = audioSourcePresetsProvider;
      var presets = ref.read(presetsProvider);
      if (presets.presets.isEmpty) {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (presets.presets.isEmpty && DateTime.now().isBefore(deadline)) {
          await Future.delayed(const Duration(milliseconds: 100));
          presets = ref.read(presetsProvider);
        }
      }
      if (presets.presets.isEmpty) {
        throw Exception("Audio source presets not loaded yet; try again");
      }
      final containerIndex = presets.selectedDownloadingContainerIndex
          .clamp(0, presets.presets.length - 1)
          .toInt();
      final container = presets.presets[containerIndex];
      if (container.qualities.isEmpty) {
        throw Exception("No download quality available for ${container.name}");
      }
      final qualityIndex = presets.selectedDownloadingQualityIndex
          .clamp(0, container.qualities.length - 1)
          .toInt();
      final downloadLocation = ref.read(
          userPreferencesProvider.select((value) => value.downloadLocation));

      final url = track.getUrlOfQuality(
        container,
        qualityIndex,
      );

      if (url == null) {
        throw Exception("No download URL found for selected codec");
      }

      final baseName = ServiceUtils.sanitizeFilename(
        "${track.query.name} - ${track.query.artists.map((e) => e.name).join(", ")}",
      );
      final savePath = join(
        downloadLocation,
        "$baseName.${container.getFileExtension()}",
      );

      final savePathFile = File(savePath);
      if (await savePathFile.exists()) {
        // dio automatically replaces the file if it exists so no deletion required
        if (!await _shouldReplaceFileOnExist(task)) {
          _setStatus(track.query, DownloadStatus.completed);
          return;
        }
      }

      // Try the app-resolved audio URL first (respects the chosen container).
      // In some regions (gcr=eg) the app's client mints region-pinned audio
      // URLs that 403 for ANY content (only 1-byte probes pass), so if that
      // fails we re-resolve the audio via youtube_explode — its URLs download
      // freely in the same region — then fall back to the mux (itag 18).
      var success = await _downloadToFile(
        task,
        track,
        url,
        savePath,
        metadataContainer: container,
      );
      if (!success && !task.cancelToken.isCancelled) {
        // NOTE: track.query.id is the source (Spotify) ID — the YouTube
        // videoId lives on track.info.id (the resolved match).
        // Flow parity: try clients in priority order, first whose audio URL
        // actually downloads wins.
        for (final clients in _downloadClients) {
          if (task.cancelToken.isCancelled) break;
          final audioUrl = await _resolveAudioUrl(
            track.info.id,
            container: container,
            clients: clients,
          );
          if (audioUrl == null) continue;
          success = await _downloadToFile(
            task,
            track,
            audioUrl,
            savePath,
            metadataContainer: container,
          );
          if (success) {
            AppLogger.log.w(
                "[download] app URL blocked for ${track.query.id}; saved audio via client ${_clientName(clients)}");
            break;
          }
        }
      }
      if (!success && !task.cancelToken.isCancelled) {
        for (final clients in _downloadClients) {
          if (task.cancelToken.isCancelled) break;
          final muxUrl = await _resolveMuxUrl(
            track.info.id,
            clients: clients,
          );
          if (muxUrl == null) continue;
          final muxSavePath = join(downloadLocation, "$baseName.mp4");
          success = await _downloadToFile(
            task,
            track,
            muxUrl,
            muxSavePath,
            metadataContainer: container,
          );
          if (success) {
            AppLogger.log.w(
                "[download] audio-only blocked for ${track.query.id}; saved mux fallback (${_clientName(clients)})");
            break;
          }
        }
      }

      if (success) {
        _setStatus(track.query, DownloadStatus.completed);
        // Invalidate the local tracks provider so the downloads page auto-refreshes
        ref.invalidate(localTracksProvider);
      } else {
        _setStatus(track.query, DownloadStatus.failed);
      }
    } catch (e, stack) {
      if (e is! DioException || e.type != DioExceptionType.cancel) {
        _setStatus(task.track, DownloadStatus.failed);
        AppLogger.log.w("[download] FAILED track=${task.track.id} error=$e");
        AppLogger.log.w("[download] STACK:\n$stack");
        AppLogger.reportError(e, stack);
      }
    }
  }

  /// Download `url` to `savePath` with progress + metadata tagging.
  /// Returns false on any HTTP failure (e.g. region-blocked audio-only).
  Future<bool> _downloadToFile(
    DownloadTask task,
    SourcedTrack track,
    String url,
    String savePath, {
    required SpotubeAudioSourceContainerPreset metadataContainer,
  }) async {
    try {
      final response = await dio.chunkDownload(
        url,
        savePath,
        cancelToken: task.cancelToken,
        onReceiveProgress: (count, total) {
          if (task.totalSizeBytes == null) {
            state = state.map((e) {
              if (e.track.id == track.query.id) {
                return e.copyWith(totalSizeBytes: total);
              }
              return e;
            }).toList();
          }
          task._downloadedBytesStreamController.add(count);
        },
        deleteOnError: true,
        fileAccessMode: FileAccessMode.write,
      );
      if (response.statusCode == null || response.statusCode! >= 400) {
        AppLogger.log.w(
            "[download] http failed track=${track.query.id} status=${response.statusCode} url=$url");
        return false;
      }
      AppLogger.log.i(
          "[download] ok track=${track.query.id} status=${response.statusCode} url=$url");

      if (metadataContainer.getFileExtension() == "weba") return true;

      final savePathFile = File(savePath);
      final imageBytes = await ServiceUtils.downloadImage(
        (task.track.album.images).asUrlString(
          placeholder: ImagePlaceholder.albumArt,
          index: 1,
        ),
      );
      // Metadata tagging is best-effort (may fail on some platforms)
      try {
        await MetadataGod.writeMetadata(
          file: savePath,
          metadata: task.track.toMetadata(
            fileLength: await savePathFile.length(),
            imageBytes: imageBytes,
          ),
        );
      } catch (_) {
        AppLogger.log
            .w("[download] metadata tagging failed (file saved without tags)");
      }
      return true;
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) rethrow;
      AppLogger.log.w(
          "[download] downloadToFile error track=${track.query.id} url=$url error=$e");
      return false;
    }
  }

  /// Resolve an audio-only stream URL via youtube_explode using the given
  /// InnerTube client (Flow parity — clients tried in priority order). Some
  /// clients mint content-locked audio URLs (e.g. ANDROID → 403 in gcr=eg)
  /// while ANDROID_VR mints URLs that download freely. Prefers the requested
  /// container (mp4 → m4a/AAC), else highest bitrate.
  Future<String?> _resolveAudioUrl(
    String videoId, {
    required SpotubeAudioSourceContainerPreset container,
    required List<YoutubeApiClient> clients,
  }) async {
    try {
      final yt = YoutubeExplode();
      try {
        final manifest = await yt.videos.streamsClient
            .getManifest(
              videoId,
              ytClients: clients,
            )
            .timeout(const Duration(seconds: 20));
        final streams = manifest.audioOnly.toList()
          ..sort((a, b) =>
              b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
        if (streams.isEmpty) return null;
        final matching =
            streams.where((s) => s.container.name == container.name).toList();
        final pick = (matching.isNotEmpty ? matching : streams).first;
        return pick.url.toString();
      } finally {
        yt.close();
      }
    } catch (e) {
      AppLogger.log.w("[download] audio resolve failed for $videoId: $e");
    }
    return null;
  }

  /// Resolve a muxed (video+audio) stream URL via youtube_explode with the
  /// given client (Flow parity) as a final fallback when audio-only is
  /// unavailable.
  Future<String?> _resolveMuxUrl(
    String videoId, {
    required List<YoutubeApiClient> clients,
  }) async {
    try {
      final yt = YoutubeExplode();
      try {
        final manifest = await yt.videos.streamsClient
            .getManifest(
              videoId,
              ytClients: clients,
            )
            .timeout(const Duration(seconds: 20));
        final muxed = manifest.muxed.toList()
          ..sort((a, b) =>
              b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
        if (muxed.isNotEmpty) return muxed.first.url.toString();
      } finally {
        yt.close();
      }
    } catch (e) {
      AppLogger.log.w("[download] mux resolve failed for $videoId: $e");
    }
    return null;
  }

  Future<void> _startDownloading() async {
    for (final task in state) {
      if (task.status == DownloadStatus.downloading) return;

      if (task.status == DownloadStatus.queued) {
        try {
          await _downloadTrack(task);
        } finally {
          // After completion, check for more queued tasks
          // Ignore errors of the prior task to allow next task to complete
          await _startDownloading();
        }
      }
    }
  }
}

final downloadManagerProvider =
    NotifierProvider<DownloadManagerNotifier, List<DownloadTask>>(
  DownloadManagerNotifier.new,
);
