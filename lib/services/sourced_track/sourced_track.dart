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
import 'package:spotube/services/logger/playback_start_trace.dart';
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

final featuredArtistRegex = RegExp(
  r"\b(ft|feat|featuring)\.?\b",
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
      .replaceAll(
          RegExp(
              r'\b(official|audio|video|lyrics?|lyric video|visualizer|topic|provided to youtube by|music video)\b',
              caseSensitive: false),
          ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

Set<String> _tokenizeSearchText(String value) {
  return _normalizeSearchText(value)
      .split(' ')
      .where((part) => part.isNotEmpty)
      .toSet();
}

double _overlapRatio(Set<String> left, Set<String> right) {
  if (left.isEmpty || right.isEmpty) return 0;
  return left.intersection(right).length / left.union(right).length;
}

class SourcedTrack extends BasicSourcedTrack {
  static const _validatedStreamTtl = Duration(minutes: 10);
  static const _refreshCooldown = Duration(seconds: 20);
  static const _signedUrlSafetyWindow = Duration(minutes: 2);
  static const _resolvedFetchCacheLimit = 250;
  static const _siblingCacheLimit = 250;
  static const _streamCacheLimit = 500;
  static const _validatedStreamCacheLimit = 1000;
  static final Map<String, Future<SourcedTrack>> _inFlightFetches = {};
  static final Map<String, SourcedTrack> _resolvedFetches = {};
  static final Map<String, Future<SourcedTrack>> _inFlightRefreshes = {};
  static final Map<String, DateTime> _recentRefreshes = {};
  static final Map<String, Future<List<SpotubeAudioSourceMatchObject>>>
      _inFlightSiblingFetches = {};
  static final Map<String, List<SpotubeAudioSourceMatchObject>>
      _siblingFetches = {};
  static final Map<String, Future<List<SpotubeAudioSourceStreamObject>>>
      _inFlightStreamFetches = {};
  static final Map<String, List<SpotubeAudioSourceStreamObject>>
      _streamFetches = {};
  static final Map<String, DateTime> _validatedStreams = {};
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
    PlaybackStartTrace.markTrack(query.id, 'sourced_track.fetch.start');
    final resolved = _resolvedFetches[query.id];
    if (resolved != null) {
      PlaybackStartTrace.markTrack(query.id, 'sourced_track.fetch.cache_hit');
      return resolved;
    }

    final inflight = _inFlightFetches[query.id];
    if (inflight != null) {
      PlaybackStartTrace.markTrack(query.id, 'sourced_track.fetch.join_inflight');
      return inflight;
    }

    final future = _fetchFromTrackInternal(query: query, ref: ref);
    _inFlightFetches[query.id] = future;

    try {
      final resolvedTrack = await future;
      _rememberResolvedTrack(query.id, resolvedTrack);
      PlaybackStartTrace.markTrack(
        query.id,
        'sourced_track.fetch.done',
        data: {'hasUrl': resolvedTrack.url != null},
      );
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
    final audioSource = await ref.read(audioSourcePluginProvider.future);
    if (audioSource == null) {
      throw MetadataPluginException.noDefaultAudioSourcePlugin();
    }

    final database = AppDatabase.current ?? ref.read(databaseProvider)!;
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

    if (cachedSource == null) {
      PlaybackStartTrace.markTrack(query.id, 'sourced_track.cache_miss');
      final rankedMatches = await _searchRankedMatches(
        ref: ref,
        query: query,
        deferred: true,
      );
      if (rankedMatches.isEmpty) {
        throw TrackNotFoundError(query);
      }
      final primaryMatch = rankedMatches.first;
      final deferredSiblings = rankedMatches.skip(1).toList();
      _rememberSiblingFetch(
        _siblingCacheKey(
          trackId: query.id,
          sourceSlug: audioSource.slug,
        ),
        rankedMatches,
      );
      PlaybackStartTrace.markTrack(
        query.id,
        'sourced_track.siblings.deferred',
        data: {'resultCount': deferredSiblings.length, 'siblingsDeferred': true},
      );

      await database.into(database.sourceMatchTable).insert(
            SourceMatchTableCompanion.insert(
              trackId: query.id,
              sourceInfo: Value(jsonEncode(primaryMatch)),
              sourceType: audioSource.slug,
            ),
          );

      final manifest = await _fetchStreams(
        ref: ref,
        match: primaryMatch,
        sourceSlug: audioSource.slug,
        trackId: query.id,
      );

      final sourcedTrack = SourcedTrack(
        ref: ref,
        siblings: const [],
        info: primaryMatch,
        source: audioSource.slug,
        sources: manifest,
        query: query,
      );

      final resolved = await sourcedTrack.resolvePlayableSource();
      return resolved;
    }
    PlaybackStartTrace.markTrack(query.id, 'sourced_track.cache_hit');
    final item = SpotubeAudioSourceMatchObject.fromJson(
      jsonDecode(cachedSource.sourceInfo),
    );
    final manifest = await _fetchStreams(
      ref: ref,
      match: item,
      sourceSlug: audioSource.slug,
      trackId: query.id,
    );

    final sourcedTrack = SourcedTrack(
      ref: ref,
      siblings: [],
      sources: manifest,
      info: item,
      query: query,
      source: audioSource.slug,
    );

    return sourcedTrack.resolvePlayableSource();
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
    final normalizedTrackName = _normalizeSearchText(track.name);
    final cleanedTrackName = _normalizeSearchText(_stripDecorators(track.name));
    final trackTokens = _tokenizeSearchText(cleanedTrackName);
    final artistNames = track.artists.map((artist) => artist.name).toList();
    final normalizedArtistNames = artistNames
        .map(_normalizeSearchText)
        .where((name) => name.isNotEmpty)
        .toList();
    final artistTokens = normalizedArtistNames
        .expand(_tokenizeSearchText)
        .where((token) => token.isNotEmpty)
        .toSet();
    final expectedDurationSeconds = track.durationMs ~/ 1000;

    return results
        .mapIndexed((index, sibling) {
          final title = sibling.title.toLowerCase();
          final normalizedTitle = _normalizeSearchText(sibling.title);
          final cleanedNormalizedTitle =
              _normalizeSearchText(_stripDecorators(sibling.title));
          final titleTokens = _tokenizeSearchText(cleanedNormalizedTitle);
          final siblingArtists =
              sibling.artists.map((artist) => artist.toLowerCase()).toList();
          final normalizedSiblingArtists =
              siblingArtists.map(_normalizeSearchText).toList();
          final siblingArtistTokens = normalizedSiblingArtists
              .expand(_tokenizeSearchText)
              .where((token) => token.isNotEmpty)
              .toSet();
          final combinedSiblingTokens = {
            ...titleTokens,
            ...siblingArtistTokens
          };
          var score = 0;

          if (normalizedTitle == normalizedTrackName) {
            score += 30;
          }
          if (cleanedNormalizedTitle == cleanedTrackName) {
            score += 32;
          } else if (cleanedNormalizedTitle.startsWith(cleanedTrackName)) {
            score += 20;
          } else if (cleanedNormalizedTitle.contains(cleanedTrackName)) {
            score += 10;
          }

          final titleOverlap = _overlapRatio(titleTokens, trackTokens);
          score += (titleOverlap * 28).round();

          final artistOverlap =
              _overlapRatio(combinedSiblingTokens, artistTokens);
          score += (artistOverlap * 18).round();

          final titleWordCount = titleTokens.length;
          final trackWordCount = trackTokens.length;
          if (titleWordCount > trackWordCount + 4) {
            score -= 6;
          }

          var hasStrongArtistMatch = false;
          for (final artistName in artistNames.map(_normalizeSearchText)) {
            final normalizedArtistName = _normalizeSearchText(artistName);
            final exactArtistMatch = normalizedSiblingArtists.any(
              (artist) =>
                  artist == normalizedArtistName ||
                  artist.startsWith(normalizedArtistName) ||
                  normalizedArtistName.startsWith(artist),
            );
            if (exactArtistMatch) {
              score += 14;
              hasStrongArtistMatch = true;
            }
            if (normalizedTitle.contains(normalizedArtistName)) {
              score += 8;
              hasStrongArtistMatch = true;
            }
          }

          if (!hasStrongArtistMatch) {
            score -= 18;
          } else if (normalizedArtistNames.any((artist) {
            return cleanedNormalizedTitle.startsWith('$artist ') ||
                cleanedNormalizedTitle.contains(' $artist ');
          })) {
            score += 6;
          }

          final durationDelta =
              (sibling.duration.inSeconds - expectedDurationSeconds).abs();
          if (durationDelta == 0) {
            score += 18;
          } else if (durationDelta <= 2) {
            score += 16;
          } else if (durationDelta <= 5) {
            score += 12;
          } else if (durationDelta <= 10) {
            score += 6;
          } else if (durationDelta <= 20) {
            score += 1;
          } else if (durationDelta >= 30) {
            score -= 12;
          }

          if (youtubeMusicRegex.hasMatch(title) ||
              siblingArtists
                  .any((artist) => youtubeMusicRegex.hasMatch(artist))) {
            score += 16;
          }
          if (officialAudioRegex.hasMatch(title)) {
            score += 14;
          }
          if (officialMusicRegex.hasMatch(title)) {
            score += 8;
          }
          if (title.contains("audio")) {
            score += 4;
          }
          if (featuredArtistRegex.hasMatch(title)) {
            score += 2;
          }

          if (musicVideoRegex.hasMatch(title)) {
            score -= 18;
          }
          if (lyricVideoRegex.hasMatch(title)) {
            score -= 18;
          }
          if (livePerformanceRegex.hasMatch(title)) {
            score -= 16;
          }
          if (remixStyleRegex.hasMatch(title)) {
            score -= 14;
          }

          return (index: index, sibling: sibling, score: score);
        })
        .sorted((a, b) {
          final scoreDiff = b.score.compareTo(a.score);
          if (scoreDiff != 0) return scoreDiff;
          return a.index.compareTo(b.index);
        })
        .map((entry) => entry.sibling)
        .toList();
  }

  static String _siblingCacheKey({
    required String trackId,
    required String sourceSlug,
  }) {
    return "$sourceSlug::$trackId";
  }

  static String _streamCacheKey({
    required String sourceSlug,
    required SpotubeAudioSourceMatchObject match,
  }) {
    return "$sourceSlug::${match.id}";
  }

  static Future<List<SpotubeAudioSourceStreamObject>> _fetchStreams({
    required Ref ref,
    required SpotubeAudioSourceMatchObject match,
    required String sourceSlug,
    String? trackId,
  }) async {
    if (trackId != null) {
      PlaybackStartTrace.markTrack(
        trackId,
        'sourced_track.streams.start',
        data: {'sourceId': match.id, 'sourceSlug': sourceSlug},
      );
    }
    final cacheKey = _streamCacheKey(sourceSlug: sourceSlug, match: match);
    final cached = _streamFetches[cacheKey];
    if (cached != null) {
      if (trackId != null) {
        PlaybackStartTrace.markTrack(
          trackId,
          'sourced_track.streams.cache_hit',
          data: {'streamCount': cached.length},
        );
      }
      return cached;
    }

    final active = _inFlightStreamFetches[cacheKey];
    if (active != null) {
      return active;
    }

    final future = (() async {
      final audioSource = await ref.read(audioSourcePluginProvider.future);
      if (audioSource == null) {
        throw MetadataPluginException.noDefaultAudioSourcePlugin();
      }

      final manifest = await audioSource.audioSource.streams(match);
      _rememberStreamFetch(cacheKey, manifest);
      if (trackId != null) {
        PlaybackStartTrace.markTrack(
          trackId,
          'sourced_track.streams.done',
          data: {'streamCount': manifest.length, 'sourceId': match.id},
        );
      }
      return manifest;
    })();

    _inFlightStreamFetches[cacheKey] = future;
    try {
      return await future;
    } finally {
      final current = _inFlightStreamFetches[cacheKey];
      if (identical(current, future)) {
        _inFlightStreamFetches.remove(cacheKey);
      }
    }
  }

  static Future<List<SpotubeAudioSourceMatchObject>> fetchSiblings({
    required SpotubeFullTrackObject query,
    required Ref ref,
  }) async {
    final audioSource = await ref.read(audioSourcePluginProvider.future);

    if (audioSource == null) {
      throw MetadataPluginException.noDefaultAudioSourcePlugin();
    }

    final cacheKey = _siblingCacheKey(
      trackId: query.id,
      sourceSlug: audioSource.slug,
    );
    final cached = _siblingFetches[cacheKey];
    if (cached != null) {
      PlaybackStartTrace.markTrack(
        query.id,
        'sourced_track.siblings.cache_hit',
        data: {'resultCount': cached.length},
      );
      return cached;
    }

    final active = _inFlightSiblingFetches[cacheKey];
    if (active != null) {
      return active;
    }

    final future = (() async {
      final ranked = await _searchRankedMatches(
        ref: ref,
        query: query,
        sourceSlugOverride: audioSource.slug,
        deferred: false,
      );
      _rememberSiblingFetch(cacheKey, ranked);
      PlaybackStartTrace.markTrack(
        query.id,
        'sourced_track.siblings.done',
        data: {'resultCount': ranked.length},
      );
      return ranked;
    })();

    _inFlightSiblingFetches[cacheKey] = future;
    try {
      return await future;
    } finally {
      final current = _inFlightSiblingFetches[cacheKey];
      if (identical(current, future)) {
        _inFlightSiblingFetches.remove(cacheKey);
      }
    }
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
    var current = this;
    if (current.url != null) return current;

    if (current.siblings.isEmpty) {
      current = await current.copyWithSibling();
    }

    return current;
  }

  Future<SourcedTrack?> swapWithSibling(
    SpotubeAudioSourceMatchObject sibling,
  ) async {
    PlaybackStartTrace.markTrack(
      query.id,
      'sourced_track.swap_sibling.start',
      data: {'fromSourceId': info.id, 'toSourceId': sibling.id},
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

    final manifest = await _fetchStreams(
      ref: ref,
      match: newSourceInfo,
      sourceSlug: audioSource.slug,
      trackId: query.id,
    );

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
    PlaybackStartTrace.markTrack(query.id, 'sourced_track.swap_sibling.done');
    return sourcedTrack;
  }

  Future<SourcedTrack?> swapWithSiblingOfIndex(int index) {
    return swapWithSibling(siblings[index]);
  }

  Future<SourcedTrack> refreshStream() async {
    PlaybackStartTrace.markTrack(query.id, 'sourced_track.refresh.start');
    final active = _inFlightRefreshes[query.id];
    if (active != null) {
      PlaybackStartTrace.markTrack(query.id, 'sourced_track.refresh.join_inflight');
      return active;
    }

    final future = _refreshStreamInternal();
    _inFlightRefreshes[query.id] = future;

    try {
      final refreshed = await future;
      _recentRefreshes[query.id] = DateTime.now();
      _pruneMap(_recentRefreshes, _resolvedFetchCacheLimit);
      PlaybackStartTrace.markTrack(
        query.id,
        'sourced_track.refresh.done',
        data: {'hasUrl': refreshed.url != null},
      );
      return refreshed;
    } finally {
      final current = _inFlightRefreshes[query.id];
      if (identical(current, future)) {
        _inFlightRefreshes.remove(query.id);
      }
    }
  }

  static Future<List<SpotubeAudioSourceMatchObject>> _searchRankedMatches({
    required Ref ref,
    required SpotubeFullTrackObject query,
    String? sourceSlugOverride,
    required bool deferred,
  }) async {
    PlaybackStartTrace.markTrack(
      query.id,
      'sourced_track.siblings.start',
      data: {'siblingsDeferred': deferred},
    );
    final audioSource = await ref.read(audioSourcePluginProvider.future);

    if (audioSource == null) {
      throw MetadataPluginException.noDefaultAudioSourcePlugin();
    }

    final sourceSlug = sourceSlugOverride ?? audioSource.slug;
    final cacheKey = _siblingCacheKey(
      trackId: query.id,
      sourceSlug: sourceSlug,
    );
    final cached = _siblingFetches[cacheKey];
    if (cached != null) {
      PlaybackStartTrace.markTrack(
        query.id,
        'sourced_track.siblings.cache_hit',
        data: {'resultCount': cached.length},
      );
      return cached;
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

    return videoResults.toSet().toList();
  }

  Future<SourcedTrack> _refreshStreamInternal() async {
    final audioSource = await ref.read(audioSourcePluginProvider.future);
    if (audioSource == null) {
      throw MetadataPluginException.noDefaultAudioSourcePlugin();
    }

    if (hasFreshValidatedStream || _isRefreshCooldownActive(query.id)) {
      PlaybackStartTrace.markTrack(
        query.id,
        'sourced_track.refresh.short_circuit',
        data: {'hasFreshValidatedStream': hasFreshValidatedStream},
      );
      _rememberResolvedTrack(query.id, this);
      return this;
    }

    final preferredStream = preferredPlaybackStream;

    List<SpotubeAudioSourceStreamObject> validStreams = [];

    Future<SpotubeAudioSourceStreamObject?> validateStream(
      SpotubeAudioSourceStreamObject source,
    ) async {
      if (_isRecentlyValidated(source.url)) {
        return source;
      }

      if (_hasFreshSignedExpiry(source.url)) {
        _markValidated(source.url);
        return source;
      }

      try {
        final res = await globalDio.head(
          source.url,
          options: Options(
            headers: {
              "user-agent": "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.6367.83 Mobile Safari/537.36",
              "referer": "https://www.youtube.com/",
            },
            validateStatus: (status) => status != null && status < 500,
          ),
        );

        if (res.statusCode! < 400) {
          _markValidated(source.url);
          return source;
        }
      } catch (e) {
        // Validation failed due to network error, treat as invalid stream
      }

      _validatedStreams.remove(source.url);
      return null;
    }

    if (preferredStream != null) {
      final validatedPreferred = await validateStream(preferredStream);
      if (validatedPreferred != null) {
        validStreams = [
          validatedPreferred,
          ...sources.where((source) => source.url != validatedPreferred.url),
        ];
      }
    }

    if (validStreams.isEmpty) {
      final validationResults = await Future.wait(
        sources.map(validateStream),
      );
      validStreams = validationResults.whereType<SpotubeAudioSourceStreamObject>().toList();
    }

    if (validStreams.isEmpty) {
      validStreams = await _fetchStreams(
        ref: ref,
        match: info,
        sourceSlug: audioSource.slug,
        trackId: query.id,
      );
    }

    final sourcedTrack = SourcedTrack(
      ref: ref,
      siblings: siblings,
      source: source,
      sources: validStreams,
      info: info,
      query: query,
    );

    final resolved = await sourcedTrack.resolvePlayableSource();
    if (resolved.url != null) {
      _markValidated(resolved.url!);
    }
    _rememberResolvedTrack(query.id, resolved);
    return resolved;
  }

  bool get hasFreshValidatedStream {
    final preferredStream = preferredPlaybackStream;
    return preferredStream != null &&
        (_isRecentlyValidated(preferredStream.url) ||
            _hasFreshSignedExpiry(preferredStream.url));
  }

  static bool _isRecentlyValidated(String url) {
    _pruneValidatedStreams();
    final validatedAt = _validatedStreams[url];
    if (validatedAt == null) return false;

    if (DateTime.now().difference(validatedAt) > _validatedStreamTtl) {
      _validatedStreams.remove(url);
      return false;
    }

    return true;
  }

  static void _markValidated(String url) {
    _validatedStreams[url] = DateTime.now();
    _pruneValidatedStreams();
  }

  static bool _hasFreshSignedExpiry(String url) {
    try {
      final uri = Uri.parse(url);
      final expireParam =
          uri.queryParameters["expire"] ?? uri.queryParameters["expires"];
      if (expireParam == null || expireParam.isEmpty) return false;

      final expireEpoch = int.tryParse(expireParam);
      if (expireEpoch == null) return false;

      final expiresAt = expireEpoch > 1000000000000
          ? DateTime.fromMillisecondsSinceEpoch(expireEpoch, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(
              expireEpoch * 1000,
              isUtc: true,
            );

      return expiresAt.isAfter(
        DateTime.now().toUtc().add(_signedUrlSafetyWindow),
      );
    } catch (_) {
      return false;
    }
  }

  static bool _isRefreshCooldownActive(String trackId) {
    final refreshedAt = _recentRefreshes[trackId];
    if (refreshedAt == null) return false;

    if (DateTime.now().difference(refreshedAt) > _refreshCooldown) {
      _recentRefreshes.remove(trackId);
      return false;
    }

    return true;
  }

  static void _rememberResolvedTrack(String trackId, SourcedTrack track) {
    _resolvedFetches[trackId] = track;
    _pruneMap(_resolvedFetches, _resolvedFetchCacheLimit);
  }

  static void _rememberSiblingFetch(
    String cacheKey,
    List<SpotubeAudioSourceMatchObject> siblings,
  ) {
    _siblingFetches[cacheKey] = siblings;
    _pruneMap(_siblingFetches, _siblingCacheLimit);
  }

  static void _rememberStreamFetch(
    String cacheKey,
    List<SpotubeAudioSourceStreamObject> streams,
  ) {
    _streamFetches[cacheKey] = streams;
    _pruneMap(_streamFetches, _streamCacheLimit);
  }

  static void _pruneValidatedStreams() {
    final now = DateTime.now();
    _validatedStreams.removeWhere(
      (_, validatedAt) => now.difference(validatedAt) > _validatedStreamTtl,
    );
    _pruneMap(_validatedStreams, _validatedStreamCacheLimit);
  }

  static void _pruneMap<K, V>(Map<K, V> map, int maxEntries) {
    while (map.length > maxEntries) {
      map.remove(map.keys.first);
    }
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
      SpotubeMediaCompressionType.lossy =>
        SpotubeAudioSourceContainerPreset.lossy(
          type: stream.type,
          name: stream.container,
          qualities: const <SpotubeAudioLossyContainerQuality>[],
        ),
    };
  }
}
