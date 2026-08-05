import 'dart:async';

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

class SyncedLyricsNotifier
    extends FamilyAsyncNotifier<SubtitleSimple, SpotubeTrackObject?> {
  SpotubeTrackObject get _track => arg!;

  /// Search LRCLib for alternative candidate lyrics
  static Future<List<SubtitleSimple>> searchLRCLibCandidates(
    SpotubeTrackObject track,
  ) async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final query = "${track.name} ${track.artists.map((a) => a.name).join(' ')}";

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

      var resData = (res.statusCode == 200 && res.data is List) ? (res.data as List) : [];

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

    return SubtitleSimple(
      lyrics: [],
      name: _track.name,
      uri: Uri.parse("https://lrclib.net"),
      rating: 0,
      provider: "LRCLib",
    );
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
        lyrics = await getLRCLibLyrics();
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
