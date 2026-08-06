import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lrc/lrc.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/models/lyrics.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/database/database.dart';
import 'package:spotube/services/dio/dio.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/youtube_engine/yt_music_engine.dart';

class SyncedLyricsNotifier
    extends FamilyAsyncNotifier<SubtitleSimple, SpotubeTrackObject?> {
  SpotubeTrackObject get _track => arg!;

  /// Search LRCLib for alternative candidate lyrics
  static Future<List<SubtitleSimple>> searchLRCLibCandidates(
    SpotubeTrackObject track,
  ) async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final query =
          "${track.name} ${track.artists.map((a) => a.name).join(' ')}";

      final res = await globalDio.getUri(
        Uri(
          scheme: "https",
          host: "lrclib.net",
          path: "/api/search",
          queryParameters: {
            "q": query,
          },
        ),
        options: Options(
          headers: {
            "User-Agent":
                "Spotube v${packageInfo.version} (https://github.com/KRTirtho/spotube)"
          },
          responseType: ResponseType.json,
          validateStatus: (_) => true,
        ),
      );

      var resData =
          (res.statusCode == 200 && res.data is List) ? (res.data as List) : [];

      if (resData.isEmpty) {
        final cleanTrackName = track.name
            .replaceAll(RegExp(r"\([^)]*\)"), "")
            .replaceAll(RegExp(r"\[[^\]]*\]"), "")
            .replaceAll(RegExp(r"-\s*.*remaster.*", caseSensitive: false), "")
            .trim();
        if (cleanTrackName.isNotEmpty && cleanTrackName != track.name) {
          final cleanQuery = "$cleanTrackName ${track.artists.first.name}";
          final cleanRes = await globalDio.getUri(
            Uri(
              scheme: "https",
              host: "lrclib.net",
              path: "/api/search",
              queryParameters: {"q": cleanQuery},
            ),
            options: Options(
              headers: {
                "User-Agent":
                    "Spotube v${packageInfo.version} (https://github.com/KRTirtho/spotube)"
              },
              responseType: ResponseType.json,
              validateStatus: (_) => true,
            ),
          );
          if (cleanRes.statusCode == 200 && cleanRes.data is List) {
            resData = cleanRes.data as List;
          }
        }
      }

      final candidates = <SubtitleSimple>[];

      for (final item in resData) {
        if (item is! Map) continue;
        final map = item.cast<String, dynamic>();
        final syncedLyricsRaw = map["syncedLyrics"] as String?;
        final plainLyricsRaw = map["plainLyrics"] as String?;
        final trackName = (map["trackName"] as String?) ?? track.name;
        final artistName = (map["artistName"] as String?) ?? "";
        final albumName = (map["albumName"] as String?) ?? "";
        final duration = (map["duration"] as num?)?.toInt() ?? 0;

        List<LyricSlice> slices = [];
        if (syncedLyricsRaw?.isNotEmpty == true) {
          try {
            slices = Lrc.parse(syncedLyricsRaw!)
                .lyrics
                .map(LyricSlice.fromLrcLine)
                .toList();
          } catch (_) {}
        } else if (plainLyricsRaw?.isNotEmpty == true) {
          slices = plainLyricsRaw!
              .split("\n")
              .map((line) => LyricSlice(text: line, time: Duration.zero))
              .toList();
        }

        if (slices.isNotEmpty) {
          final isSynced = slices.any((s) => s.time > Duration.zero);
          candidates.add(
            SubtitleSimple(
              lyrics: slices,
              name: "$trackName - $artistName ($albumName)",
              uri: res.realUri,
              rating: isSynced ? 100 : 50,
              provider: "LRCLib (${duration}s)",
            ),
          );
        }
      }

      // Preserve LRCLib search rank: candidate 0 is top search match.
      // If top search match is plain lyrics, display plain lyrics automatically.
      // Users can pick a synced candidate manually from the modal if desired.
      candidates.sort((a, b) {
        final aIndex = candidates.indexOf(a);
        final bIndex = candidates.indexOf(b);
        return aIndex.compareTo(bIndex);
      });

      return candidates;
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      return [];
    }
  }

  /// Lyrics credits: [lrclib.net](https://lrclib.net) and their contributors
  /// Thanks for their generous public API
  Future<SubtitleSimple> getLRCLibLyrics() async {
    final packageInfo = await PackageInfo.fromPlatform();

    try {
      final res = await globalDio.getUri(
        Uri(
          scheme: "https",
          host: "lrclib.net",
          path: "/api/get",
          queryParameters: {
            "artist_name": _track.artists.first.name,
            "track_name": _track.name,
            "album_name": _track.album.name,
            if (_track.durationMs > 0)
              "duration": (_track.durationMs / 1000).toInt().toString(),
          },
        ),
        options: Options(
          headers: {
            "User-Agent":
                "Spotube v${packageInfo.version} (https://github.com/KRTirtho/spotube)"
          },
          responseType: ResponseType.json,
          validateStatus: (_) => true,
        ),
      );

      if (res.statusCode == 200 && res.data is Map<String, dynamic>) {
        final json = res.data as Map<String, dynamic>;
        final syncedLyricsRaw = json["syncedLyrics"] as String?;
        final syncedLyrics = syncedLyricsRaw?.isNotEmpty == true
            ? Lrc.parse(syncedLyricsRaw!)
                .lyrics
                .map(LyricSlice.fromLrcLine)
                .toList()
            : null;

        if (syncedLyrics?.isNotEmpty == true) {
          return SubtitleSimple(
            lyrics: syncedLyrics!,
            name: _track.name,
            uri: res.realUri,
            rating: 100,
            provider: "LRCLib",
          );
        }

        final plainLyricsRaw = json["plainLyrics"] as String?;
        if (plainLyricsRaw?.isNotEmpty == true) {
          final plainLyrics = plainLyricsRaw!
              .split("\n")
              .map((line) => LyricSlice(text: line, time: Duration.zero))
              .toList();

          return SubtitleSimple(
            lyrics: plainLyrics,
            name: _track.name,
            uri: res.realUri,
            rating: 50,
            provider: "LRCLib",
          );
        }
      }
    } catch (_) {}

    // Fallback: query search endpoint if exact /api/get fails
    final searchCandidates = await searchLRCLibCandidates(_track);
    if (searchCandidates.isNotEmpty) {
      return searchCandidates.first;
    }

    return _emptyLyrics("LRCLib");
  }

  /// SimpMusic synced lyrics provider (Flow has this too).
  /// API: https://api-lyrics.simpmusic.org/v1/{videoId}
  /// Response: {"type":"success","data":[{...lyrics data...}]}
  Future<SubtitleSimple> getSimpMusicLyrics() async {
    try {
      final res = await globalDio.getUri(
        Uri.parse("https://api-lyrics.simpmusic.org/v1/${_track.id}"),
        options: Options(
          headers: {
            "User-Agent": "SimpMusicLyrics/1.0",
            "Accept": "application/json",
          },
          responseType: ResponseType.json,
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode != 200) return _emptyLyrics("SimpMusic");

      final root = res.data;
      final items = switch (root) {
        List l => l,
        Map m when m["data"] is List => m["data"] as List,
        _ => <dynamic>[],
      };
      if (items.isEmpty) return _emptyLyrics("SimpMusic");

      // Pick the closest duration match when multiple candidates exist.
      dynamic best = items.first;
      if (items.length > 1 && _track.durationMs > 0) {
        final targetSec = (_track.durationMs / 1000).round();
        dynamic bestItem;
        var bestDiff = 1 << 30;
        for (final item in items) {
          if (item is! Map) continue;
          final d = ((item["durationSeconds"] ?? item["duration"] ?? 0) as num)
              .toInt();
          final diff = (d - targetSec).abs();
          if (diff < bestDiff) {
            bestDiff = diff;
            bestItem = item;
          }
        }
        if (bestItem != null) best = bestItem;
      }

      final durationSeconds = (best is Map
          ? best["durationSeconds"] ?? best["duration"]
          : null) as num?;
      final slices = _parseSimpMusicItem(best, durationSeconds?.toInt());
      if (slices.isEmpty) return _emptyLyrics("SimpMusic");
      final isSynced = slices.any((s) => s.time > Duration.zero);
      return SubtitleSimple(
        lyrics: slices,
        name: _track.name,
        uri: res.realUri,
        rating: isSynced ? 100 : 50,
        provider: "SimpMusic",
      );
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      return _emptyLyrics("SimpMusic");
    }
  }

  /// Parse one SimpMusic item: richSyncLyrics (word-level JSON) → syncedLyrics
  /// (LRC) → plainLyrics. Our model is line-level, so rich-sync words are
  /// collapsed into line timestamps via `ts` + line text `x`.
  List<LyricSlice> _parseSimpMusicItem(dynamic item, int? durationSeconds) {
    if (item is! Map) return [];

    num normalizeTime(num value) {
      final v = value.toDouble();
      final isMillis = v > 1000 ||
          (durationSeconds != null &&
              durationSeconds > 0 &&
              v > durationSeconds + 60);
      return isMillis ? v : v * 1000;
    }

    // 1. richSyncLyrics — [{"ts":1.2,"te":5.6,"l":[{"c":"word","o":0}],"x":"line"}]
    final richSync = item["richSyncLyrics"] as String?;
    if (richSync?.isNotEmpty == true) {
      try {
        final parsed = jsonDecode(richSync!);
        if (parsed is List && parsed.isNotEmpty) {
          final slices = <LyricSlice>[];
          for (final raw in parsed) {
            if (raw is! Map) continue;
            final ts = ((raw["ts"] as num?) ?? 0);
            final x = raw["x"] as String?;
            final words = raw["l"] as List?;
            var text = x?.trim() ?? "";
            if (text.isEmpty && words != null) {
              text = words
                  .map((w) => (w is Map ? w["c"] : null)?.toString() ?? "")
                  .join(" ")
                  .trim();
            }
            if (text.isEmpty) continue;
            slices.add(LyricSlice(
              time: Duration(milliseconds: normalizeTime(ts).round()),
              text: text,
            ));
          }
          if (slices.isNotEmpty) return slices;
        }
      } catch (_) {}
    }

    // 2. syncedLyrics — LRC
    final synced = item["syncedLyrics"] as String?;
    if (synced?.isNotEmpty == true) {
      try {
        final slices =
            Lrc.parse(synced!).lyrics.map(LyricSlice.fromLrcLine).toList();
        if (slices.isNotEmpty) return slices;
      } catch (_) {}
    }

    // 3. plainLyrics / plainLyric
    final plain = (item["plainLyrics"] ?? item["plainLyric"]) as String?;
    if (plain?.isNotEmpty == true) {
      return plain!
          .split("\n")
          .map((line) => LyricSlice(text: line.trim(), time: Duration.zero))
          .toList();
    }
    return [];
  }

  SubtitleSimple _emptyLyrics(String provider) {
    return SubtitleSimple(
      lyrics: [],
      name: _track.name,
      uri: Uri.parse("https://$provider"),
      rating: 0,
      provider: provider,
    );
  }

  /// YouTube Music native lyrics provider (Flow parity): plain text from the
  /// song's lyrics panel. Lowest priority since it has no sync, but it covers
  /// songs LRCLib/SimpMusic don't have.
  Future<SubtitleSimple> getYouTubeMusicLyrics() async {
    try {
      final text = await YtMusicEngine.fetchLyrics(_track.id);
      if (text == null || text.trim().isEmpty) {
        return _emptyLyrics("YouTube Music");
      }
      final slices = text
          .trim()
          .split("\n")
          .map((line) => LyricSlice(text: line.trim(), time: Duration.zero))
          .toList();
      if (slices.isEmpty) return _emptyLyrics("YouTube Music");
      return SubtitleSimple(
        lyrics: slices,
        name: _track.name,
        uri: Uri.parse("https://music.youtube.com/watch?v=${_track.id}"),
        rating: 50,
        provider: "YouTube Music",
      );
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      return _emptyLyrics("YouTube Music");
    }
  }

  Future<void> updateSelectedLyrics(SubtitleSimple newLyrics) async {
    final database = ref.read(databaseProvider);
    await database.into(database.lyricsTable).insert(
          LyricsTableCompanion.insert(
            trackId: _track.id,
            data: newLyrics,
          ),
          mode: InsertMode.replace,
        );
    state = AsyncValue.data(newLyrics);
    ref.invalidate(syncedLyricsMapProvider(_track));
  }

  @override
  FutureOr<SubtitleSimple> build(track) async {
    try {
      final database = ref.watch(databaseProvider);

      if (track == null) {
        throw "No track currently";
      }

      final cachedLyrics = await (database.select(database.lyricsTable)
            ..where((tbl) => tbl.trackId.equals(track.id)))
          .map((row) => row.data)
          .getSingleOrNull();

      SubtitleSimple? lyrics = cachedLyrics;

      if (lyrics == null || lyrics.lyrics.isEmpty) {
        // Prefer YouTube Music's official lyrics (Flow's primary native
        // source), then synced providers (SimpMusic, LRCLib) as fallbacks.
        lyrics = await getYouTubeMusicLyrics();
        if (lyrics.lyrics.isEmpty) {
          lyrics = await getSimpMusicLyrics();
        }
        if (lyrics.lyrics.isEmpty) {
          lyrics = await getLRCLibLyrics();
        }
      }

      if (lyrics.lyrics.isEmpty) {
        throw Exception("Unable to find lyrics");
      }

      if (cachedLyrics == null || cachedLyrics.lyrics.isEmpty) {
        await database.into(database.lyricsTable).insert(
              LyricsTableCompanion.insert(
                trackId: track.id,
                data: lyrics,
              ),
              mode: InsertMode.replace,
            );
      }

      return lyrics;
    } catch (e, stackTrace) {
      AppLogger.reportError(e, stackTrace);
      rethrow;
    }
  }
}

final syncedLyricsDelayProvider = StateProvider<int>((ref) => 0);

final syncedLyricsProvider = AsyncNotifierProviderFamily<SyncedLyricsNotifier,
    SubtitleSimple, SpotubeTrackObject?>(
  () => SyncedLyricsNotifier(),
);

final syncedLyricsMapProvider =
    FutureProvider.family((ref, SpotubeTrackObject? track) async {
  final syncedLyrics = await ref.watch(syncedLyricsProvider(track).future);

  final isStaticLyrics =
      syncedLyrics.lyrics.every((l) => l.time == Duration.zero);

  final lyricsMap = syncedLyrics.lyrics
      .map((lyric) => {lyric.time.inSeconds: lyric.text})
      .reduce((accumulator, lyricSlice) => {...accumulator, ...lyricSlice});

  return (static: isStaticLyrics, lyricsMap: lyricsMap);
});
