import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/models/playback/track_sources.dart';
import 'package:spotube/provider/database/database.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/dio/dio.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/metadata/errors/exceptions.dart';

import 'package:spotube/services/sourced_track/exceptions.dart';
import 'package:spotube/utils/service_utils.dart';

final officialMusicRegex = RegExp(
  r"official\s(video|audio|music\svideo|lyric\svideo|visualizer)",
  caseSensitive: false,
);
final officialAudioRegex = RegExp(
  r"official\s(audio|audio\svideo)",
  caseSensitive: false,
);
final musicVideoRegex = RegExp(
  r"\b(official\svideo|music\svideo|mv)\b",
  caseSensitive: false,
);
final lyricVideoRegex = RegExp(
  r"\b(lyric\svideo|lyrics?)\b",
  caseSensitive: false,
);
final livePerformanceRegex = RegExp(
  r"\b(live|performance|concert|session|acoustic|karaoke)\b",
  caseSensitive: false,
);
final remixStyleRegex = RegExp(
  r"\b(remix|cover|sped\s?up|slowed|nightcore)\b",
  caseSensitive: false,
);
final youtubeMusicRegex = RegExp(
  r"\b(provided to youtube by|topic)\b",
  caseSensitive: false,
);

String _normalizeSearchText(String value) {
  return value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _stripDecorators(String value) {
  return value
      .replaceAll(RegExp(r'\([^)]*\)'), ' ')
      .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
      .replaceAll(RegExp(r'\b(official|audio|video|lyrics?|lyric video|visualizer|topic|provided to youtube by|music video)\b', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

class SourcedTrack extends BasicSourcedTrack {
  static final Map<String, Future<SourcedTrack>> _inFlightFetches = {};
  static final Map<String, SourcedTrack> _resolvedFetches = {};
  final Ref ref;

  SourcedTrack({
    required this.ref,
    required super.info,
    required super.query,
    required super.source,
    required super.siblings,
    required super.sources,
  });

  static Future<SourcedTrack> fetchFromTrack({
    required SpotubeFullTrackObject query,
    required Ref ref,
  }) async {
    final resolved = _resolvedFetches[query.id];
    if (resolved != null) {
      AppLogger.trace("[sourced_track] reuse resolved track=${query.id}");
      AppLogger.criticalTrace("[sourced_track] reuse resolved track=${query.id}");
      return resolved;
    }

    final inflight = _inFlightFetches[query.id];
    if (inflight != null) {
      AppLogger.trace("[sourced_track] join in-flight track=${query.id}");
      return inflight;
    }

    final future = _fetchFromTrackInternal(query: query, ref: ref);
    _inFlightFetches[query.id] = future;

    try {
      final resolvedTrack = await future;
      _resolvedFetches[query.id] = resolvedTrack;
      return resolvedTrack;
    } finally {
      final active = _inFlightFetches[query.id];
      if (identical(active, future)) {
        _inFlightFetches.remove(query.id);
      }
    }
  }

  static Future<SourcedTrack> _fetchFromTrackInternal({
    required SpotubeFullTrackObject query,
    required Ref ref,
  }) async {
    AppLogger.trace("[sourced_track] fetchFromTrack start track=${query.id}");
    AppLogger.criticalTrace("[sourced_track] fetchFromTrack start track=${query.id}");
    AppLogger.criticalTrace("[sourced_track] await audioSourcePluginProvider track=${query.id}");
    final audioSource = await ref.read(audioSourcePluginProvider.future);
    AppLogger.criticalTrace("[sourced_track] audioSourcePluginProvider done track=${query.id} null=${audioSource == null}");
    AppLogger.criticalTrace(
      "[sourced_track] audio source slug sync track=${query.id} null=${audioSource == null}",
    );
    if (audioSource == null) {
      throw MetadataPluginException.noDefaultAudioSourcePlugin();
    }

    AppLogger.criticalTrace("[sourced_track] await database track=${query.id}");
    final database = AppDatabase.current ?? ref.read(databaseProvider)!;
    AppLogger.criticalTrace("[sourced_track] database done track=${query.id}");
    AppLogger.criticalTrace("[sourced_track] db cache query start track=${query.id}");
    final cachedSource = await (database.select(database.sourceMatchTable)
          ..where((s) =>
              s.trackId.equals(query.id) &
              s.sourceType.equals(audioSource.slug))
          ..limit(1)
          ..orderBy([
            (s) =>
                OrderingTerm(expression: s.createdAt, mode: OrderingMode.desc),
          ]))
        .get()
        .then((s) => s.firstOrNull);
    AppLogger.criticalTrace(
      "[sourced_track] db cache query done track=${query.id} hit=${cachedSource != null}",
    );

    if (cachedSource == null) {
      AppLogger.trace("[sourced_track] cache miss track=${query.id}");
      AppLogger.criticalTrace("[sourced_track] cache miss track=${query.id}");
      final siblings = await fetchSiblings(ref: ref, query: query);
      if (siblings.isEmpty) {
        throw TrackNotFoundError(query);
      }

      await database.into(database.sourceMatchTable).insert(
            SourceMatchTableCompanion.insert(
              trackId: query.id,
              sourceInfo: Value(jsonEncode(siblings.first)),
              sourceType: audioSource.slug,
            ),
          );

      AppLogger.criticalTrace(
        "[sourced_track] streams start track=${query.id} source=${siblings.first.id}",
      );
      final manifest = await audioSource.audioSource.streams(siblings.first);
      AppLogger.criticalTrace(
        "[sourced_track] streams done track=${query.id} source=${siblings.first.id} count=${manifest.length}",
      );

      final sourcedTrack = SourcedTrack(
        ref: ref,
        siblings: siblings.skip(1).toList(),
        info: siblings.first,
        source: audioSource.slug,
        sources: manifest,
        query: query,
      );

      final resolved = await sourcedTrack.resolvePlayableSource();
      AppLogger.trace(
        "[sourced_track] fetchFromTrack resolved track=${query.id} url=${resolved.url != null} siblings=${resolved.siblings.length}",
      );
      AppLogger.criticalTrace(
        "[sourced_track] fetchFromTrack resolved track=${query.id} url=${resolved.url != null} siblings=${resolved.siblings.length}",
      );
      return resolved;
    }
    AppLogger.trace("[sourced_track] cache hit track=${query.id}");
    AppLogger.criticalTrace("[sourced_track] cache hit track=${query.id}");
    final item = SpotubeAudioSourceMatchObject.fromJson(
      jsonDecode(cachedSource.sourceInfo),
    );
    AppLogger.criticalTrace(
      "[sourced_track] streams start track=${query.id} source=${item.id}",
    );
    final manifest = await audioSource.audioSource.streams(item);
    AppLogger.criticalTrace(
      "[sourced_track] streams done track=${query.id} source=${item.id} count=${manifest.length}",
    );

    final sourcedTrack = SourcedTrack(
      ref: ref,
      siblings: [],
      sources: manifest,
      info: item,
      query: query,
      source: audioSource.slug,
    );

    AppLogger.log.i("${query.name}: ${sourcedTrack.url}");

    final resolved = await sourcedTrack.resolvePlayableSource();
    AppLogger.trace(
      "[sourced_track] fetchFromTrack resolved track=${query.id} url=${resolved.url != null} siblings=${resolved.siblings.length}",
    );
    AppLogger.criticalTrace(
      "[sourced_track] fetchFromTrack resolved track=${query.id} url=${resolved.url != null} siblings=${resolved.siblings.length}",
    );
    return resolved;
  }

  static List<SpotubeAudioSourceMatchObject> rankResults(
    List<SpotubeAudioSourceMatchObject> results,
    SpotubeFullTrackObject track,
  ) {
    return results
        .map((sibling) {
          int score = 0;

          for (final artist in track.artists) {
            final isSameChannelArtist =
                sibling.artists.any((a) => a.toLowerCase() == artist.name);

            if (isSameChannelArtist) {
              score += 1;
            }

            final titleContainsArtist =
                sibling.title.toLowerCase().contains(artist.name.toLowerCase());

            if (titleContainsArtist) {
              score += 1;
            }
          }

          final titleContainsTrackName =
              sibling.title.toLowerCase().contains(track.name.toLowerCase());

          final hasOfficialFlag =
              officialMusicRegex.hasMatch(sibling.title.toLowerCase());

          if (titleContainsTrackName) {
            score += 3;
          }

          if (hasOfficialFlag) {
            score += 1;
          }

          if (hasOfficialFlag && titleContainsTrackName) {
            score += 2;
          }

          return (sibling: sibling, score: score);
        })
        .sorted((a, b) => b.score.compareTo(a.score))
        .map((e) => e.sibling)
        .toList();
  }

  static List<SpotubeAudioSourceMatchObject> rankResultsExperimental(
    List<SpotubeAudioSourceMatchObject> results,
    SpotubeFullTrackObject track,
  ) {
    final trackName = track.name.toLowerCase();
    final normalizedTrackName = _normalizeSearchText(track.name);
    final artistNames = track.artists.map((artist) => artist.name.toLowerCase());
    final normalizedArtistNames =
        track.artists.map((artist) => _normalizeSearchText(artist.name)).toList();
    final expectedDurationSeconds = track.durationMs ~/ 1000;

    return results
        .map((sibling) {
          final title = sibling.title.toLowerCase();
          final normalizedTitle = _normalizeSearchText(title);
          final cleanedNormalizedTitle =
              _normalizeSearchText(_stripDecorators(sibling.title));
          final siblingArtists =
              sibling.artists.map((artist) => artist.toLowerCase()).toList();
          final normalizedSiblingArtists =
              siblingArtists.map(_normalizeSearchText).toList();
          var score = 0;

          if (title.contains(trackName)) {
            score += 8;
          }
          if (normalizedTitle == normalizedTrackName) {
            score += 12;
          } else if (cleanedNormalizedTitle == normalizedTrackName) {
            score += 9;
          } else if (cleanedNormalizedTitle.contains(normalizedTrackName)) {
            score += 4;
          }

          final titleWordCount = cleanedNormalizedTitle
              .split(' ')
              .where((part) => part.isNotEmpty)
              .length;
          final trackWordCount = normalizedTrackName
              .split(' ')
              .where((part) => part.isNotEmpty)
              .length;
          if (titleWordCount > trackWordCount + 3) {
            score -= 4;
          }

          var hasStrongArtistMatch = false;
          for (final artistName in artistNames) {
            final normalizedArtistName = _normalizeSearchText(artistName);
            final exactArtistMatch = normalizedSiblingArtists.any(
              (artist) =>
                  artist == normalizedArtistName ||
                  artist.contains(normalizedArtistName) ||
                  normalizedArtistName.contains(artist),
            );
            if (exactArtistMatch) {
              score += 5;
              hasStrongArtistMatch = true;
            }
            if (normalizedTitle.contains(normalizedArtistName)) {
              score += 3;
              hasStrongArtistMatch = true;
            }
          }

          if (!hasStrongArtistMatch) {
            score -= 10;
          } else if (normalizedArtistNames.any(
            (artist) => normalizedTitle.startsWith('$artist '),
          )) {
            score += 3;
          }

          final durationDelta =
              (sibling.duration.inSeconds - expectedDurationSeconds).abs();
          if (durationDelta <= 2) {
            score += 6;
          } else if (durationDelta <= 5) {
            score += 4;
          } else if (durationDelta <= 10) {
            score += 2;
          } else if (durationDelta >= 30) {
            score -= 3;
          }

          if (youtubeMusicRegex.hasMatch(title)) {
            score += 8;
          }
          if (officialAudioRegex.hasMatch(title)) {
            score += 5;
          }
          if (title.contains("audio")) {
            score += 2;
          }
          if (officialMusicRegex.hasMatch(title)) {
            score += 1;
          }

          if (musicVideoRegex.hasMatch(title)) {
            score -= 8;
          }
          if (lyricVideoRegex.hasMatch(title)) {
            score -= 8;
          }
          if (livePerformanceRegex.hasMatch(title)) {
            score -= 6;
          }
          if (remixStyleRegex.hasMatch(title)) {
            score -= 4;
          }

          return (sibling: sibling, score: score);
        })
        .sorted((a, b) => b.score.compareTo(a.score))
        .map((entry) => entry.sibling)
        .toList();
  }

  static Future<List<SpotubeAudioSourceMatchObject>> fetchSiblings({
    required SpotubeFullTrackObject query,
    required Ref ref,
  }) async {
    AppLogger.trace("[sourced_track] fetchSiblings start track=${query.id}");
    AppLogger.criticalTrace("[sourced_track] fetchSiblings start track=${query.id}");
    final audioSource = await ref.read(audioSourcePluginProvider.future);

    if (audioSource == null) {
      throw MetadataPluginException.noDefaultAudioSourcePlugin();
    }

    final videoResults = <SpotubeAudioSourceMatchObject>[];
    final experimentalScoring = ref.read(
      userPreferencesProvider.select((value) => value.experimentalScoring),
    );

    final searchResults = await audioSource.audioSource.matches(query);

    if (experimentalScoring) {
      videoResults.addAll(rankResultsExperimental(searchResults, query));
    } else if (ServiceUtils.onlyContainsEnglish(query.name)) {
      videoResults.addAll(searchResults);
    } else {
      videoResults.addAll(rankResults(searchResults, query));
    }

    final ranked = videoResults.toSet().toList();
    AppLogger.trace(
      "[sourced_track] fetchSiblings done track=${query.id} results=${ranked.length}",
    );
    AppLogger.criticalTrace(
      "[sourced_track] fetchSiblings done track=${query.id} results=${ranked.length}",
    );
    return ranked;
  }

  Future<SourcedTrack> copyWithSibling() async {
    if (siblings.isNotEmpty) {
      return this;
    }
    final fetchedSiblings = await fetchSiblings(ref: ref, query: query);

    return SourcedTrack(
      ref: ref,
      siblings: fetchedSiblings.where((s) => s.id != info.id).toList(),
      source: source,
      sources: sources,
      info: info,
      query: query,
    );
  }

  Future<SourcedTrack> resolvePlayableSource() async {
    AppLogger.trace(
      "[sourced_track] resolvePlayableSource start track=${query.id} url=${url != null} siblings=${siblings.length}",
    );
    AppLogger.criticalTrace(
      "[sourced_track] resolvePlayableSource start track=${query.id} url=${url != null} siblings=${siblings.length}",
    );
    var current = this;
    if (current.url != null) return current;

    if (current.siblings.isEmpty) {
      current = await current.copyWithSibling();
      if (current.url != null) return current;
    }

    final triedSourceIds = <String>{current.info.id};

    while (current.url == null) {
      final nextSibling = current.siblings.firstWhereOrNull(
        (sibling) => !triedSourceIds.contains(sibling.id),
      );

      if (nextSibling == null) {
        return current;
      }

      triedSourceIds.add(nextSibling.id);
      final swapped = await current.swapWithSibling(nextSibling);
      if (swapped == null) {
        return current;
      }

      current = swapped;
    }

    AppLogger.trace(
      "[sourced_track] resolvePlayableSource done track=${query.id} url=${current.url != null} siblings=${current.siblings.length}",
    );
    AppLogger.criticalTrace(
      "[sourced_track] resolvePlayableSource done track=${query.id} url=${current.url != null} siblings=${current.siblings.length}",
    );
    return current;
  }

  Future<SourcedTrack?> swapWithSibling(
    SpotubeAudioSourceMatchObject sibling,
  ) async {
    AppLogger.trace(
      "[sourced_track] swapWithSibling track=${query.id} from=${info.id} to=${sibling.id}",
    );
    if (sibling.id == info.id) {
      return null;
    }

    final audioSource = await ref.read(audioSourcePluginProvider.future);
    if (audioSource == null) {
      throw MetadataPluginException.noDefaultAudioSourcePlugin();
    }

    // a sibling source that was fetched from the search results
    final isStepSibling = siblings.none((s) => s.id == sibling.id);

    final newSourceInfo = isStepSibling
        ? sibling
        : siblings.firstWhere((s) => s.id == sibling.id);

    final newSiblings = siblings.where((s) => s.id != sibling.id).toList()
      ..insert(0, info);

    final manifest = await audioSource.audioSource.streams(newSourceInfo);

    final database = ref.read(databaseProvider);

    // Delete the old Entry
    await (database.sourceMatchTable.delete()
          ..where(
            (table) =>
                table.trackId.equals(query.id) &
                table.sourceType.equals(audioSource.slug),
          ))
        .go();

    await database.into(database.sourceMatchTable).insert(
          SourceMatchTableCompanion.insert(
            trackId: query.id,
            sourceInfo: Value(jsonEncode(sibling)),
            sourceType: audioSource.slug,
            createdAt: Value(DateTime.now()),
          ),
          mode: InsertMode.replace,
        );

    final sourcedTrack = SourcedTrack(
      ref: ref,
      source: source,
      siblings: newSiblings,
      sources: manifest,
      info: newSourceInfo,
      query: query,
    );

    _resolvedFetches[query.id] = sourcedTrack;
    return sourcedTrack;
  }

  Future<SourcedTrack?> swapWithSiblingOfIndex(int index) {
    return swapWithSibling(siblings[index]);
  }

  Future<SourcedTrack> refreshStream() async {
    AppLogger.trace("[sourced_track] refreshStream start track=${query.id}");
    final audioSource = await ref.read(audioSourcePluginProvider.future);
    if (audioSource == null) {
      throw MetadataPluginException.noDefaultAudioSourcePlugin();
    }

    List<SpotubeAudioSourceStreamObject> validStreams = [];

    final stringBuffer = StringBuffer();
    for (final source in sources) {
      final res = await globalDio.head(
        source.url,
        options:
            Options(validateStatus: (status) => status != null && status < 500),
      );

      stringBuffer.writeln(
        "[${query.id}] ${res.statusCode} ${source.container} ${source.codec} ${source.bitrate}",
      );

      if (res.statusCode! < 400) {
        validStreams.add(source);
      }
    }

    AppLogger.log.d(stringBuffer.toString());

    if (validStreams.isEmpty) {
      validStreams = await audioSource.audioSource.streams(info);
    }

    final sourcedTrack = SourcedTrack(
      ref: ref,
      siblings: siblings,
      source: source,
      sources: validStreams,
      info: info,
      query: query,
    );

    AppLogger.log.i("Refreshing ${query.name}: ${sourcedTrack.url}");

    final resolved = await sourcedTrack.resolvePlayableSource();
    AppLogger.trace(
      "[sourced_track] refreshStream done track=${query.id} url=${resolved.url != null}",
    );
    _resolvedFetches[query.id] = resolved;
    return resolved;
  }

  SpotubeAudioSourceStreamObject? get preferredPlaybackStream {
    if (sources.isEmpty) return null;

    final sorted = [...sources]..sort((a, b) {
      int score(SpotubeAudioSourceStreamObject source) {
        var value = 0;
        if (source.container == "mp4") {
          value += 4;
        } else if (source.container == "webm") {
          value += 3;
        } else {
          value += 1;
        }

        if (source.type == SpotubeMediaCompressionType.lossless) {
          value += 2;
        }

        return value;
      }

      final scoreDiff = score(b).compareTo(score(a));
      if (scoreDiff != 0) return scoreDiff;

      final bitrateDiff = (b.bitrate ?? 0).compareTo(a.bitrate ?? 0);
      if (bitrateDiff != 0) return bitrateDiff;

      final sampleRateDiff = (b.sampleRate ?? 0).compareTo(a.sampleRate ?? 0);
      if (sampleRateDiff != 0) return sampleRateDiff;

      return (b.bitDepth ?? 0).compareTo(a.bitDepth ?? 0);
    });

    return sorted.firstOrNull;
  }

  String? get url {
    return preferredPlaybackStream?.url;
  }

  /// Returns the URL of the track based on the codec and quality preferences.
  /// If an exact match is not found, it will return the closest match based on
  /// the user's audio quality preference.
  ///
  /// If no sources match the codec, it will return the first or last source
  /// based on the user's audio quality preference.
  SpotubeAudioSourceStreamObject? getStreamOfQuality(
    SpotubeAudioSourceContainerPreset preset,
    int qualityIndex,
  ) {
    if (sources.isEmpty) return null;

    final quality = preset.qualities[qualityIndex];

    final exactMatch = sources.firstWhereOrNull(
      (source) {
        if (source.container != preset.name) return false;

        if (quality case SpotubeAudioLosslessContainerQuality()) {
          return source.sampleRate == quality.sampleRate &&
              source.bitDepth == quality.bitDepth;
        } else {
          return source.bitrate ==
              (quality as SpotubeAudioLossyContainerQuality).bitrate;
        }
      },
    );

    if (exactMatch != null) {
      return exactMatch;
    }

    // Find the preset with closest quality to the supplied quality
    final matchingContainerSources = sources.where((source) {
      return source.container == preset.name;
    }).toList();

    if (matchingContainerSources.isEmpty) {
      return qualityIndex >= (preset.qualities.length / 2)
          ? sources.last
          : sources.first;
    }

    return matchingContainerSources.reduce((prev, curr) {
      if (quality is SpotubeAudioLosslessContainerQuality) {
        final prevDiff = ((prev.sampleRate ?? 0) - quality.sampleRate).abs() +
            ((prev.bitDepth ?? 0) - quality.bitDepth).abs();
        final currDiff = ((curr.sampleRate ?? 0) - quality.sampleRate).abs() +
            ((curr.bitDepth ?? 0) - quality.bitDepth).abs();
        return currDiff < prevDiff ? curr : prev;
      } else {
        final prevDiff = ((prev.bitrate ?? 0) -
                (quality as SpotubeAudioLossyContainerQuality).bitrate)
            .abs();
        final currDiff = ((curr.bitrate ?? 0) - quality.bitrate).abs();
        return currDiff < prevDiff ? curr : prev;
      }
    });
  }

  String? getUrlOfQuality(
    SpotubeAudioSourceContainerPreset preset,
    int qualityIndex,
  ) {
    return getStreamOfQuality(preset, qualityIndex)?.url;
  }

  SpotubeAudioSourceContainerPreset? get qualityPreset {
    final stream = preferredPlaybackStream;
    if (stream == null) return null;

    return switch (stream.type) {
      SpotubeMediaCompressionType.lossless =>
        SpotubeAudioSourceContainerPreset.lossless(
          type: stream.type,
          name: stream.container,
          qualities: const <SpotubeAudioLosslessContainerQuality>[],
        ),
      SpotubeMediaCompressionType.lossy => SpotubeAudioSourceContainerPreset.lossy(
          type: stream.type,
          name: stream.container,
          qualities: const <SpotubeAudioLossyContainerQuality>[],
        ),
    };
  }
}
