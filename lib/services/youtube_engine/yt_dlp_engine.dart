import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/collections/routes.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/kv_store/kv_store.dart';
import 'package:spotube/services/youtube_engine/deno_binary.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/youtube_engine/newpipe_engine.dart';
import 'package:spotube/services/youtube_engine/yt_dlp_auth_browser.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:spotube/services/youtube_engine/youtube_explode_engine.dart';
import 'package:spotube/services/youtube_engine/yt_dlp_binary.dart';
import 'package:spotube/services/youtube_engine/yt_dlp_worker.dart';
import 'package:spotube/utils/platform.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:yt_dlp_dart/yt_dlp_dart.dart';
// ignore: depend_on_referenced_packages
import 'package:http_parser/http_parser.dart';

enum _YtDlpAuthAction {
  retryWithBrowserSession,
  useDifferentEngine,
}

final class _YtDlpFallbackRequested implements Exception {
  const _YtDlpFallbackRequested();
}

class _YtDlpExtracted<T> {
  final T data;
  final String backend;

  const _YtDlpExtracted(this.data, this.backend);
}

class _TimedCacheEntry<T> {
  final T value;
  final DateTime createdAt;

  const _TimedCacheEntry(this.value, this.createdAt);
}

class YtDlpEngine implements YouTubeEngine {
  static const _authCooldown = Duration(minutes: 5);
  static const _manifestCacheTtl = Duration(minutes: 15);
  static const _searchPrimaryCount = 7;
  static const _searchFallbackCount = 12;
  static const _searchCacheLimit = 200;
  static const _browserCookieSources = [
    YtDlpAuthBrowser.firefox,
    YtDlpAuthBrowser.edge,
    YtDlpAuthBrowser.chrome,
    YtDlpAuthBrowser.chromium,
    YtDlpAuthBrowser.brave,
  ];
  static DateTime? _authCooldownUntil;
  static Future<_YtDlpAuthAction>? _authPromptFuture;
  static final Map<String, Future<Object?>> _inFlightExtractions = {};
  static final Map<String, Future<Map<String, dynamic>>> _inFlightVideoInfo =
      {};
  static final Map<String, Map<String, dynamic>> _resolvedVideoInfo = {};
  static final Map<String, Future<List<dynamic>>> _inFlightFormats = {};
  static final Map<String, _TimedCacheEntry<List<dynamic>>> _resolvedFormats =
      {};
  static final Map<String, Future<List<Video>>> _inFlightSearches = {};
  static final Map<String, List<Video>> _resolvedSearches = {};

  void _trace(String message) {
    AppLogger.trace("[yt_dlp_engine] $message");
  }

  void _critical(String message) {
    AppLogger.criticalTrace("[yt_dlp_engine] $message");
  }

  void _logWorkerFallback(String operation, Object error) {
    AppLogger.agentDebug(
      'yt_dlp_engine.dart:worker_fallback',
      'yt_dlp.worker.fallback',
      {
        'operation': operation,
        'error': error.toString(),
      },
      hypothesisId: 'PLAYBACK_START',
      runId: 'startup-trace',
    );
  }

  YtDlpWorkerClient get _preferredWorker {
    return YtDlpExecutionContext.isBackground
        ? YtDlpWorkerClient.background
        : YtDlpWorkerClient.foreground;
  }

  bool get _allowFallbackForCurrentContext => !YtDlpExecutionContext.isBackground;

  String get _currentPriorityLabel => YtDlpExecutionContext.currentPriority.name;

  String get _currentWorkerLabel =>
      YtDlpExecutionContext.isBackground ? 'background' : 'foreground';

  String _normalizeSearchQuery(String query) {
    return query.trim().toLowerCase();
  }

  String _searchTarget(String query, int count) => "ytsearch$count:$query";

  List<Video> _parseSearchPayload(String stdout) {
    final json = stdout.trim().startsWith("[")
        ? jsonDecode(stdout) as List
        : jsonDecode(
            "[${stdout.split("\n").where((s) => s.trim().isNotEmpty).join(",")}]",
          ) as List;

    return json.map((e) => _parseInfo(e)).toList();
  }

  static void _pruneCache<K, V>(Map<K, V> map, int maxEntries) {
    while (map.length > maxEntries) {
      map.remove(map.keys.first);
    }
  }

  Future<List<Video>> _searchVideosUncached(String query, int count) async {
    final stopwatch = Stopwatch()..start();
    final stdout = await _runWithFallback(
      "search lookup",
      () => _extractWithAuthRetry<String>(
        target: _searchTarget(query, count),
        formatSpecifiers: "%()j",
        extractor: (authArgs) async {
          if (authArgs.isEmpty) {
            try {
              final results =
                  await YtDlpWorkerClient.instance.searchVideos(query, count);
              return _YtDlpExtracted(jsonEncode(results), 'worker');
            } catch (error) {
              _logWorkerFallback('search', error);
            }
          }

          final jsRuntimeArgs = await _jsRuntimeArgs();
          return _YtDlpExtracted(
            await YtDlp.instance.extractInfoString(
              _searchTarget(query, count),
              formatSpecifiers: "%()j",
              extraArgs: [
                "--skip-download",
                "--no-check-certificate",
                "--quiet",
                "--ignore-errors",
                "--flat-playlist",
                "--no-playlist",
                ...jsRuntimeArgs,
                ...authArgs,
              ],
            ),
            'cli',
          );
        },
      ),
      (fallback) async {
        final videos = await fallback.searchVideos(query);
        return _YtDlpExtracted(
          jsonEncode(
            videos
                .take(count)
                .map(
                  (video) => {
                    "id": video.id.value,
                    "title": video.title,
                    "channel": video.author,
                    "channel_id": video.channelId.value,
                    "upload_date":
                        video.uploadDate?.millisecondsSinceEpoch.toString() ??
                            "",
                    "description": video.description,
                    "duration": video.duration?.inSeconds ?? 0,
                    "tags": video.keywords,
                    "view_count": video.engagement.viewCount,
                    "like_count": video.engagement.likeCount,
                    "is_live": video.isLive,
                  },
                )
                .toList(),
          ),
          fallback.runtimeType.toString(),
        );
      },
    );

    final videos = _parseSearchPayload(stdout.data);
    AppLogger.agentDebug(
      'yt_dlp_engine.dart:search',
      'yt_dlp.search.done',
      {
        'query': query,
        'count': count,
        'elapsedMs': stopwatch.elapsedMilliseconds,
        'resultCount': videos.length,
        'backend': stdout.backend,
        'priority': _currentPriorityLabel,
        'worker': stdout.backend == 'worker' ? _currentWorkerLabel : 'cli_fallback',
      },
      hypothesisId: 'PLAYBACK_START',
      runId: 'startup-trace',
    );
    return videos;
  }

  YouTubeEngine _getFallbackEngine(
      {bool preferAuthenticatedResilience = false}) {
    if (preferAuthenticatedResilience) {
      return YouTubeExplodeEngine();
    }

    if (NewPipeEngine.isAvailableForPlatform) {
      return NewPipeEngine();
    }

    return YouTubeExplodeEngine();
  }

  bool _shouldFallback(Object error) {
    if (error is _YtDlpFallbackRequested) return true;

    final message = error.toString().toLowerCase();
    return message.contains("too many requests") ||
        message.contains("http error 429") ||
        message.contains("this video is not available") ||
        message.contains("unable to download webpage") ||
        message.contains("sign in to confirm you're not a bot") ||
        message.contains("no supported javascript runtime") ||
        message.contains("command failed with exit code 1");
  }

  bool _requiresAuthentication(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains("sign in to confirm you're not a bot") ||
        message.contains("use --cookies-from-browser") ||
        message.contains("use --cookies") ||
        message.contains("login_required");
  }

  bool get _isInAuthCooldown {
    final cooldownUntil = _authCooldownUntil;
    if (cooldownUntil == null) return false;
    if (DateTime.now().isAfter(cooldownUntil)) {
      _authCooldownUntil = null;
      return false;
    }
    return true;
  }

  void _markAuthCooldown() {
    _authCooldownUntil = DateTime.now().add(_authCooldown);
  }

  String _fallbackEngineLabel(YouTubeEngine fallback) {
    return switch (fallback) {
      NewPipeEngine() => "NewPipe",
      YouTubeExplodeEngine() => "YouTubeExplode",
      _ => fallback.runtimeType.toString(),
    };
  }

  YoutubeClientEngine _fallbackPreference(YouTubeEngine fallback) {
    return switch (fallback) {
      NewPipeEngine() => YoutubeClientEngine.newPipe,
      _ => YoutubeClientEngine.youtubeExplode,
    };
  }

  Future<void> _switchPreferredEngine(YouTubeEngine fallback) async {
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;

    ProviderScope.containerOf(
      context,
      listen: false,
    ).read(userPreferencesProvider.notifier).setYoutubeClientEngine(
          _fallbackPreference(fallback),
        );
  }

  Future<_YtDlpAuthAction> _promptForAuthAction(YouTubeEngine fallback) async {
    final existingPrompt = _authPromptFuture;
    if (existingPrompt != null) {
      return existingPrompt;
    }

    final future = _showAuthPrompt(fallback);
    _authPromptFuture = future;

    try {
      return await future;
    } finally {
      if (identical(_authPromptFuture, future)) {
        _authPromptFuture = null;
      }
    }
  }

  Future<_YtDlpAuthAction> _showAuthPrompt(YouTubeEngine fallback) async {
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) {
      return _YtDlpAuthAction.useDifferentEngine;
    }

    final fallbackLabel = _fallbackEngineLabel(fallback);
    final result = await showDialog<_YtDlpAuthAction>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: AlertDialog(
              title: const Text("yt-dlp needs authentication"),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(
                  "YouTube blocked yt-dlp on this network or session. Spotube can try your signed-in browser session, or switch to $fallbackLabel instead.",
                ),
              ),
              actions: [
                Button.secondary(
                  onPressed: () {
                    Navigator.of(dialogContext).pop(
                      _YtDlpAuthAction.useDifferentEngine,
                    );
                  },
                  child: Text("Use $fallbackLabel"),
                ),
                Button.primary(
                  onPressed: () {
                    Navigator.of(dialogContext).pop(
                      _YtDlpAuthAction.retryWithBrowserSession,
                    );
                  },
                  child: const Text("Retry with browser session"),
                ),
              ],
            ),
          ),
        );
      },
    );

    return result ?? _YtDlpAuthAction.useDifferentEngine;
  }

  Future<bool> _ensureDenoForRetry(YouTubeEngine fallback) async {
    if (await DenoBinary.ensureAvailable(downloadIfMissing: false)) {
      return true;
    }

    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) {
      return false;
    }

    final fallbackLabel = _fallbackEngineLabel(fallback);
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        var isDownloading = false;
        double? progress;
        String? errorText;

        return StatefulBuilder(
          builder: (context, setState) {
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: AlertDialog(
                  title: const Text("Deno is required for yt-dlp"),
                  content: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 12,
                      children: [
                        const Text(
                          "yt-dlp needs Deno to solve YouTube's challenge scripts. Download Deno automatically, or switch to another engine instead.",
                        ),
                        if (isDownloading) ...[
                          LinearProgressIndicator(value: progress ?? 0),
                          Text(
                            progress == null
                                ? "Downloading Deno..."
                                : "Downloading Deno... ${(progress! * 100).clamp(0, 100).toStringAsFixed(0)}%",
                          ),
                        ],
                        if (errorText != null)
                          Text(
                            errorText!,
                            style: const TextStyle(color: Colors.red),
                          ),
                      ],
                    ),
                  ),
                  actions: [
                    Button.secondary(
                      onPressed: isDownloading
                          ? null
                          : () => Navigator.of(dialogContext).pop(false),
                      child: Text("Use $fallbackLabel"),
                    ),
                    Button.primary(
                      onPressed: isDownloading
                          ? null
                          : () async {
                              setState(() {
                                isDownloading = true;
                                progress = 0;
                                errorText = null;
                              });

                              final installed =
                                  await DenoBinary.ensureAvailable(
                                downloadIfMissing: true,
                                onReceiveProgress: (received, total) {
                                  setState(() {
                                    progress =
                                        total > 0 ? received / total : null;
                                  });
                                },
                              );

                              if (!dialogContext.mounted) return;

                              if (installed) {
                                Navigator.of(dialogContext).pop(true);
                                return;
                              }

                              setState(() {
                                isDownloading = false;
                                errorText =
                                    "Spotube couldn't download Deno automatically. You can switch engines and try again later.";
                              });
                            },
                      child: Text(
                        isDownloading
                            ? "Downloading Deno..."
                            : "Download Deno automatically",
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    return result ?? false;
  }

  Future<List<String>> _jsRuntimeArgs() async {
    final denoPath = await DenoBinary.findInstalledBinaryPath();
    if (denoPath == null) return const [];

    final value = denoPath == "deno" ? "deno" : "deno:$denoPath";
    return ["--js-runtimes", value];
  }

  Future<_YtDlpExtracted<T>> _runExtractWithBrowserCookies<T>({
    required String target,
    required String formatSpecifiers,
    required Future<_YtDlpExtracted<T>> Function(List<String> extraArgs)
        extractor,
  }) async {
    final selectedBrowser = KVStoreService.ytDlpAuthBrowser;
    final browsers = selectedBrowser == YtDlpAuthBrowser.auto
        ? _browserCookieSources
        : [selectedBrowser];
    final failures = <String>[];
    Object? lastError;
    StackTrace? lastStackTrace;

    for (final browser in browsers) {
      final browserArg = browser.ytDlpArgument;
      if (browserArg == null) continue;
      try {
        return await extractor([
          "--cookies-from-browser",
          browserArg,
        ]);
      } catch (error, stackTrace) {
        failures.add("${browser.label}: ${error.toString()}");
        lastError = error;
        lastStackTrace = stackTrace;
      }
    }

    if (lastError != null && lastStackTrace != null) {
      await AppLogger.reportError(
        Exception(
          "yt-dlp browser-session retry failed. ${failures.join(' | ')}",
        ),
        lastStackTrace,
        "yt-dlp authenticated retry failed for $target",
      );
      throw Exception(
        "yt-dlp browser-session retry failed. ${failures.join(' | ')}",
      );
    }

    throw Exception("yt-dlp authenticated retry failed for $target");
  }

  Future<_YtDlpExtracted<T>> _extractWithAuthRetry<T>({
    required String target,
    required String formatSpecifiers,
    required Future<_YtDlpExtracted<T>> Function(List<String> extraArgs)
        extractor,
  }) async {
    final inflightKey = "$target|$formatSpecifiers";
    final active = _inFlightExtractions[inflightKey];
    if (active != null) {
      _trace("extract join target=$target");
      return await active as _YtDlpExtracted<T>;
    }

    final future = _extractWithAuthRetryInternal<T>(
      target: target,
      formatSpecifiers: formatSpecifiers,
      extractor: extractor,
    );
    _inFlightExtractions[inflightKey] = future;

    try {
      return await future;
    } finally {
      final current = _inFlightExtractions[inflightKey];
      if (identical(current, future)) {
        _inFlightExtractions.remove(inflightKey);
      }
    }
  }

  Future<_YtDlpExtracted<T>> _extractWithAuthRetryInternal<T>({
    required String target,
    required String formatSpecifiers,
    required Future<_YtDlpExtracted<T>> Function(List<String> extraArgs)
        extractor,
  }) async {
    final stopwatch = Stopwatch()..start();
    _trace("extract start target=$target");
    _critical("extract start target=$target");
    if (_isInAuthCooldown) {
      throw const _YtDlpFallbackRequested();
    }

    try {
      final result = await extractor(const []);
      _authCooldownUntil = null;
      _trace("extract success target=$target");
      _critical("extract success target=$target");
      AppLogger.agentDebug(
        'yt_dlp_engine.dart:extract',
        'yt_dlp.extract.done',
        {
          'target': target,
          'formatSpecifiers': formatSpecifiers,
          'elapsedMs': stopwatch.elapsedMilliseconds,
          'mode': 'primary',
          'backend': result.backend,
          'priority': _currentPriorityLabel,
          'worker':
              result.backend == 'worker' ? _currentWorkerLabel : 'cli_fallback',
        },
        hypothesisId: 'PLAYBACK_START',
        runId: 'startup-trace',
      );
      return result;
    } catch (error) {
      _trace("extract primary failed target=$target error=$error");
      _critical("extract primary failed target=$target error=$error");
      if (!_requiresAuthentication(error)) rethrow;
    }

    final fallback = _getFallbackEngine(preferAuthenticatedResilience: true);
    final authAction = await _promptForAuthAction(fallback);
    if (authAction == _YtDlpAuthAction.useDifferentEngine) {
      _markAuthCooldown();
      await _switchPreferredEngine(fallback);
      throw const _YtDlpFallbackRequested();
    }

    if (!await _ensureDenoForRetry(fallback)) {
      _markAuthCooldown();
      await _switchPreferredEngine(fallback);
      throw const _YtDlpFallbackRequested();
    }

    try {
      final result = await _runExtractWithBrowserCookies(
        target: target,
        formatSpecifiers: formatSpecifiers,
        extractor: extractor,
      );
      _authCooldownUntil = null;
      _trace("extract browser retry success target=$target");
      _critical("extract browser retry success target=$target");
      AppLogger.agentDebug(
        'yt_dlp_engine.dart:extract',
        'yt_dlp.extract.done',
        {
          'target': target,
          'formatSpecifiers': formatSpecifiers,
          'elapsedMs': stopwatch.elapsedMilliseconds,
          'mode': 'browser_retry',
          'backend': result.backend,
          'priority': _currentPriorityLabel,
          'worker':
              result.backend == 'worker' ? _currentWorkerLabel : 'cli_fallback',
        },
        hypothesisId: 'PLAYBACK_START',
        runId: 'startup-trace',
      );
      return result;
    } catch (error) {
      _trace("extract browser retry failed target=$target error=$error");
      _critical("extract browser retry failed target=$target error=$error");
      _markAuthCooldown();
      rethrow;
    }
  }

  Future<T> _runWithFallback<T>(
    String operation,
    Future<T> Function() primary,
    Future<T> Function(YouTubeEngine fallback) secondary,
  ) async {
    try {
      return await primary();
    } catch (error, stackTrace) {
      if (!_allowFallbackForCurrentContext) rethrow;
      if (!_shouldFallback(error)) rethrow;

      final fallback = _getFallbackEngine(
        preferAuthenticatedResilience: _requiresAuthentication(error),
      );
      if (error is! _YtDlpFallbackRequested) {
        await AppLogger.reportError(
          error,
          stackTrace,
          "yt-dlp $operation failed, falling back to ${fallback.runtimeType}",
        );
      }
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

  DateTime _parsePublishDate(dynamic rawValue) {
    if (rawValue == null) return DateTime.now();

    final value = rawValue.toString().trim();
    if (value.isEmpty) return DateTime.now();

    if (RegExp(r'^\d{8}$').hasMatch(value)) {
      final year = int.tryParse(value.substring(0, 4));
      final month = int.tryParse(value.substring(4, 6));
      final day = int.tryParse(value.substring(6, 8));
      if (year != null && month != null && day != null) {
        return DateTime(year, month, day);
      }
    }

    final asInt = int.tryParse(value);
    if (asInt != null) {
      if (value.length >= 13) {
        return DateTime.fromMillisecondsSinceEpoch(asInt);
      }
      return DateTime.fromMillisecondsSinceEpoch(asInt * 1000);
    }

    return DateTime.tryParse(value) ?? DateTime.now();
  }

  static const _unknownChannelId = 'UC0000000000000000000000';

  ChannelId _parseChannelId(Map<String, dynamic> info) {
    final candidates = <String>[
      info["channel_id"]?.toString() ?? "",
      info["uploader_id"]?.toString() ?? "",
      info["channel_url"]?.toString() ?? "",
      info["uploader_url"]?.toString() ?? "",
    ];

    for (final candidate in candidates) {
      final value = candidate.trim();
      if (value.isEmpty) continue;

      final parsed = ChannelId.parseChannelId(value);
      if (parsed != null) {
        return ChannelId(parsed);
      }
    }

    return ChannelId(_unknownChannelId);
  }

  Video _parseInfo(Map<String, dynamic> info) {
    final uploadDate = info["upload_date"]?.toString() ?? "";
    final publishDate = _parsePublishDate(uploadDate);
    return Video(
      VideoId(info["id"]),
      info["title"]?.toString() ?? "",
      info["channel"]?.toString() ??
          info["uploader"]?.toString() ??
          "",
      _parseChannelId(info),
      publishDate,
      uploadDate.isNotEmpty ? uploadDate : publishDate.toIso8601String(),
      publishDate,
      info["description"]?.toString() ?? "",
      Duration(seconds: ((info["duration"] ?? 0) as num).toInt()),
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

  Future<Map<String, dynamic>> _extractVideoInfo(String videoId) async {
    final cached = _resolvedVideoInfo[videoId];
    if (cached != null) {
      return cached;
    }

    final active = _inFlightVideoInfo[videoId];
    if (active != null) {
      return active;
    }

    final rawFuture = _extractWithAuthRetry<Map<String, dynamic>>(
      target: "https://www.youtube.com/watch?v=$videoId",
      formatSpecifiers: "%()j",
      extractor: (authArgs) async {
        if (authArgs.isEmpty) {
          try {
            return _YtDlpExtracted(
              await _preferredWorker.getVideo(videoId),
              'worker',
            );
          } catch (error) {
            if (!_allowFallbackForCurrentContext) rethrow;
            _logWorkerFallback('get_video', error);
          }
        }

        final jsRuntimeArgs = await _jsRuntimeArgs();
        return _YtDlpExtracted(
          await YtDlp.instance.extractInfo(
            "https://www.youtube.com/watch?v=$videoId",
            formatSpecifiers: "%()j",
            extraArgs: [
              "--no-check-certificate",
              "--quiet",
              "--ignore-errors",
              ...jsRuntimeArgs,
              ...authArgs,
            ],
          ) as Map<String, dynamic>,
          'cli',
        );
      },
    );
    final future = rawFuture.then((value) => value.data);

    _inFlightVideoInfo[videoId] = future;
    try {
      final resolved = await future;
      _resolvedVideoInfo[videoId] = resolved;
      return resolved;
    } finally {
      final current = _inFlightVideoInfo[videoId];
      if (identical(current, future)) {
        _inFlightVideoInfo.remove(videoId);
      }
    }
  }

  Future<List<dynamic>> _extractFormats(String videoId) async {
    final cacheKey = videoId;
    final cached = _resolvedFormats[cacheKey];
    if (cached != null) {
      final age = DateTime.now().difference(cached.createdAt);
      if (age <= _manifestCacheTtl) {
        AppLogger.agentDebug(
          'yt_dlp_engine.dart:manifest_cache',
          'yt_dlp.manifest.cache_hit',
          {
            'videoId': videoId,
            'priority': _currentPriorityLabel,
            'ageMs': age.inMilliseconds,
          },
          hypothesisId: 'PLAYBACK_START',
          runId: 'startup-trace',
        );
        return cached.value;
      }
      _resolvedFormats.remove(cacheKey);
    }

    final active = _inFlightFormats[cacheKey];
    if (active != null) {
      return active;
    }

    final rawFuture = _extractWithAuthRetry<List<dynamic>>(
      target: "https://www.youtube.com/watch?v=$videoId",
      formatSpecifiers: "%(formats)j",
      extractor: (authArgs) async {
        if (authArgs.isEmpty) {
          try {
            return _YtDlpExtracted(
              await _preferredWorker.getStreamManifest(videoId),
              'worker',
            );
          } catch (error) {
            if (!_allowFallbackForCurrentContext) rethrow;
            _logWorkerFallback('get_stream_manifest', error);
          }
        }

        final jsRuntimeArgs = await _jsRuntimeArgs();
        return _YtDlpExtracted(
          (await YtDlp.instance.extractInfo(
            "https://www.youtube.com/watch?v=$videoId",
            formatSpecifiers: "%(formats)j",
            extraArgs: [
              "--no-check-certificate",
              "--quiet",
              "--ignore-errors",
              ...jsRuntimeArgs,
              ...authArgs,
            ],
          ) as List)
              .cast<dynamic>(),
          'cli',
        );
      },
    );
    final future = rawFuture.then((value) => value.data);

    _inFlightFormats[cacheKey] = future;
    try {
      final resolved = await future;
      _resolvedFormats[cacheKey] = _TimedCacheEntry(resolved, DateTime.now());
      _pruneCache(_resolvedFormats, _searchCacheLimit);
      return resolved;
    } finally {
      final current = _inFlightFormats[cacheKey];
      if (identical(current, future)) {
        _inFlightFormats.remove(cacheKey);
      }
    }
  }

  static Future<bool> isInstalled() async {
    return isAvailableForPlatform &&
        await YtDlpBinary.ensureAvailable(downloadIfMissing: false);
  }

  @override
  Future<StreamManifest> getStreamManifest(String videoId) async {
    return _runWithFallback(
      "stream manifest lookup",
      () async {
        final formats = await _extractFormats(videoId);
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
        final info = await _extractVideoInfo(videoId);
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
        if (!_isInAuthCooldown) {
          try {
            final combined = await _preferredWorker.getVideoWithStreamInfo(videoId);
            final manifest = _parseFormats(combined.$2, videoId);
            if (manifest.audioOnly.isEmpty) {
              throw Exception("yt-dlp returned no playable audio streams");
            }

            return (_parseInfo(combined.$1), manifest);
          } catch (error) {
            if (!_allowFallbackForCurrentContext) rethrow;
            _logWorkerFallback('get_video_with_stream_info', error);
          }
        }

        final jsRuntimeArgs = await _jsRuntimeArgs();
        final extracted = await _extractWithAuthRetry<Map<String, dynamic>>(
          target: "https://www.youtube.com/watch?v=$videoId",
          formatSpecifiers: "%()j",
          extractor: (authArgs) async {
            return _YtDlpExtracted(
              await YtDlp.instance.extractInfo(
                "https://www.youtube.com/watch?v=$videoId",
                formatSpecifiers: "%()j",
                extraArgs: [
                  "--no-check-certificate",
                  "--quiet",
                  "--ignore-errors",
                  ...jsRuntimeArgs,
                  ...authArgs,
                ],
              ) as Map<String, dynamic>,
              'cli',
            );
          },
        );
        final info = extracted.data;
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
    _trace("searchVideos query=$query");
    final cacheKey = _normalizeSearchQuery(query);
    final cached = _resolvedSearches[cacheKey];
    if (cached != null) {
      return cached;
    }

    final active = _inFlightSearches[cacheKey];
    if (active != null) {
      return active;
    }

    final future = (() async {
      final primaryResults =
          await _searchVideosUncached(query, _searchPrimaryCount);
      final results = primaryResults.length >= 5
          ? primaryResults
          : await _searchVideosUncached(query, _searchFallbackCount);
      _resolvedSearches[cacheKey] = results;
      _pruneCache(_resolvedSearches, _searchCacheLimit);
      return results;
    })();

    _inFlightSearches[cacheKey] = future;
    try {
      return await future;
    } finally {
      final current = _inFlightSearches[cacheKey];
      if (identical(current, future)) {
        _inFlightSearches.remove(cacheKey);
      }
    }
  }

  @override
  void dispose() {}
}
