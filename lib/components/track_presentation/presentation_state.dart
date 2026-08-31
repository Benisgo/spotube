import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:collection/collection.dart';
import 'package:fuzzywuzzy/fuzzywuzzy.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/pages/library/user_local_tracks/user_local_tracks.dart';
import 'package:spotube/provider/metadata_plugin/library/tracks.dart';
import 'package:spotube/provider/metadata_plugin/tracks/album.dart';
import 'package:spotube/provider/metadata_plugin/tracks/playlist.dart';
import 'package:spotube/utils/service_utils.dart';

class PresentationState {
  final List<SpotubeTrackObject> selectedTracks;
  final List<SpotubeTrackObject> presentationTracks;
  final SortBy sortBy;
  final String searchQuery;
  final bool isSearchLoading;
  final bool reversed;

  const PresentationState({
    required this.selectedTracks,
    required this.presentationTracks,
    required this.sortBy,
    required this.searchQuery,
    required this.isSearchLoading,
    this.reversed = false,
  });

  PresentationState copyWith({
    List<SpotubeTrackObject>? selectedTracks,
    List<SpotubeTrackObject>? presentationTracks,
    SortBy? sortBy,
    String? searchQuery,
    bool? isSearchLoading,
    bool? reversed,
  }) {
    return PresentationState(
      selectedTracks: selectedTracks ?? this.selectedTracks,
      presentationTracks: presentationTracks ?? this.presentationTracks,
      sortBy: sortBy ?? this.sortBy,
      searchQuery: searchQuery ?? this.searchQuery,
      isSearchLoading: isSearchLoading ?? this.isSearchLoading,
      reversed: reversed ?? this.reversed,
    );
  }
}

int _scorePresentationTrack(
  String query,
  String title,
  String album,
  String artists,
) {
  final normalizedQuery = query.toLowerCase();
  final normalizedTitle = title.toLowerCase();
  final normalizedAlbum = album.toLowerCase();
  final normalizedArtists = artists.toLowerCase();
  final combined =
      [normalizedTitle, normalizedAlbum, normalizedArtists].join(" ");

  if (normalizedTitle == normalizedQuery) return 300;
  if (normalizedTitle.startsWith(normalizedQuery)) return 240;
  if (normalizedTitle.contains(normalizedQuery)) return 200;
  if (normalizedArtists == normalizedQuery) return 180;
  if (normalizedArtists.contains(normalizedQuery)) return 150;
  if (normalizedAlbum == normalizedQuery) return 140;
  if (normalizedAlbum.contains(normalizedQuery)) return 120;

  return [
    weightedRatio(normalizedTitle, normalizedQuery),
    weightedRatio(normalizedArtists, normalizedQuery),
    weightedRatio(normalizedAlbum, normalizedQuery),
    weightedRatio(combined, normalizedQuery),
  ].reduce((a, b) => a > b ? a : b);
}

List<int> _rankPresentationTrackIndices(Map<String, Object?> payload) {
  final query = payload["query"]! as String;
  final tracks = (payload["tracks"]! as List).cast<Map<String, Object?>>();

  return tracks
      .asMap()
      .entries
      .map((entry) => (
            entry.key,
            _scorePresentationTrack(
              query,
              entry.value["name"]! as String,
              entry.value["album"]! as String,
              entry.value["artists"]! as String,
            ),
          ))
      .where((entry) => entry.$2 >= 35)
      .sorted((a, b) {
        final scoreComparison = b.$2.compareTo(a.$2);
        if (scoreComparison != 0) return scoreComparison;
        return a.$1.compareTo(b.$1);
      })
      .map((entry) => entry.$1)
      .toList();
}

class PresentationStateNotifier
    extends AutoDisposeFamilyNotifier<PresentationState, Object> {
  bool _didRequestSavedTracksSearchPrefetch = false;
  int _searchGeneration = 0;

  @override
  PresentationState build(collection) {
    if (arg case SpotubeSimplePlaylistObject() || SpotubeSimpleAlbumObject()) {
      if (isSavedTrackPlaylist) {
        ref.listen(
          metadataPluginSavedTracksProvider,
          (previous, next) {
            next.whenData((value) {
              unawaited(
                _refreshPresentationTracks(sourceTracks: value.items),
              );
            });
          },
        );
      } else {
        ref.listen(
          arg is SpotubeSimplePlaylistObject
              ? metadataPluginPlaylistTracksProvider(
                  (arg as SpotubeSimplePlaylistObject).id)
              : metadataPluginAlbumTracksProvider(
                  (arg as SpotubeSimpleAlbumObject).id),
          (previous, next) {
            next.whenData((value) {
              unawaited(
                _refreshPresentationTracks(sourceTracks: value.items),
              );
            });
          },
        );
      }
    }

    ref.onDispose(() {
      _searchGeneration++;
    });

    return PresentationState(
      selectedTracks: [],
      presentationTracks: tracks,
      sortBy: SortBy.none,
      searchQuery: "",
      isSearchLoading: false,
    );
  }

  bool get isSavedTrackPlaylist =>
      arg is SpotubeSimplePlaylistObject &&
      (arg as SpotubeSimplePlaylistObject).id == "user-liked-tracks";

  List<SpotubeTrackObject> get tracks {
    assert(
      arg is SpotubeSimplePlaylistObject || arg is SpotubeSimpleAlbumObject,
      "arg must be SpotubeSimplePlaylistObject or SpotubeSimpleAlbumObject",
    );

    final isPlaylist = arg is SpotubeSimplePlaylistObject;

    final tracks = switch ((isPlaylist, isSavedTrackPlaylist)) {
          (true, true) =>
            ref.read(metadataPluginSavedTracksProvider).asData?.value.items,
          (true, false) => ref
              .read(metadataPluginPlaylistTracksProvider(
                  (arg as SpotubeSimplePlaylistObject).id))
              .asData
              ?.value
              .items,
          _ => ref
              .read(metadataPluginAlbumTracksProvider(
                  (arg as SpotubeSimpleAlbumObject).id))
              .asData
              ?.value
              .items,
        } ??
        <SpotubeFullTrackObject>[];

    return tracks;
  }

  Future<List<SpotubeTrackObject>> _buildPresentationTracks(
    List<SpotubeTrackObject> sourceTracks,
    SortBy sortBy,
    String query,
  ) async {
    if (query.isEmpty) {
      return ServiceUtils.sortTracks(sourceTracks, sortBy);
    }

    final List<SpotubeTrackObject> filteredTracks;
    if (sourceTracks.length < 150) {
      filteredTracks = sourceTracks
          .asMap()
          .entries
          .map((entry) => (
                entry.key,
                _scorePresentationTrack(
                  query,
                  entry.value.name,
                  entry.value.album.name,
                  entry.value.artists.asString(),
                ),
                entry.value,
              ))
          .where((entry) => entry.$2 >= 35)
          .sorted((a, b) {
            final scoreComparison = b.$2.compareTo(a.$2);
            if (scoreComparison != 0) return scoreComparison;
            return a.$1.compareTo(b.$1);
          })
          .map((entry) => entry.$3)
          .toList();
    } else {
      final rankedIndexes = await compute(
        _rankPresentationTrackIndices,
        {
          "query": query,
          "tracks": sourceTracks
              .map((track) => <String, Object?>{
                    "name": track.name,
                    "album": track.album.name,
                    "artists": track.artists.asString(),
                  })
              .toList(),
        },
      );
      filteredTracks =
          rankedIndexes.map((index) => sourceTracks[index]).toList();
    }

    return ServiceUtils.sortTracks(filteredTracks, sortBy);
  }

  Future<void> _refreshPresentationTracks({
    List<SpotubeTrackObject>? sourceTracks,
    String? query,
    SortBy? sortBy,
  }) async {
    final effectiveQuery = query ?? state.searchQuery;
    final effectiveSortBy = sortBy ?? state.sortBy;
    final effectiveSourceTracks = sourceTracks ?? tracks;
    final generation = ++_searchGeneration;
    final shouldShowLoading =
        effectiveQuery.isNotEmpty && effectiveSourceTracks.length >= 150;

    if (shouldShowLoading) {
      state = state.copyWith(isSearchLoading: true);
    }

    final presentationTracks = await _buildPresentationTracks(
      effectiveSourceTracks,
      effectiveSortBy,
      effectiveQuery,
    );

    if (generation != _searchGeneration) return;

    // Reverse is an independent visual toggle — persist it across re-sorts
    // and re-searches (applied after sorting).
    final visibleTracks = state.reversed
        ? presentationTracks.reversed.toList()
        : presentationTracks;

    state = state.copyWith(
      presentationTracks: visibleTracks,
      sortBy: effectiveSortBy,
      searchQuery: effectiveQuery,
      isSearchLoading: false,
    );
  }

  void selectTrack(SpotubeTrackObject track) {
    if (state.selectedTracks.any((e) => e.id == track.id)) {
      return;
    }

    state = state.copyWith(
      selectedTracks: [...state.selectedTracks, track],
    );
  }

  void selectAllTracks() {
    state = state.copyWith(
      selectedTracks: tracks,
    );
  }

  void deselectTrack(SpotubeTrackObject track) {
    state = state.copyWith(
      selectedTracks: state.selectedTracks.where((e) => e != track).toList(),
    );
  }

  void deselectAllTracks() {
    state = state.copyWith(
      selectedTracks: [],
    );
  }

  void filterTracks(String query) {
    final trimmedQuery = query.trim();

    if (trimmedQuery.isNotEmpty &&
        isSavedTrackPlaylist &&
        !_didRequestSavedTracksSearchPrefetch &&
        (ref.read(metadataPluginSavedTracksProvider).asData?.value.hasMore ??
            false)) {
      _didRequestSavedTracksSearchPrefetch = true;
      unawaited(
        ref.read(metadataPluginSavedTracksProvider.notifier).fetchAll(),
      );
    }

    state = state.copyWith(searchQuery: trimmedQuery);
    unawaited(
      _refreshPresentationTracks(
        sourceTracks: tracks,
        query: trimmedQuery,
      ),
    );
  }

  void clearFilter() {
    state = state.copyWith(searchQuery: "");
    unawaited(
      _refreshPresentationTracks(
        sourceTracks: tracks,
        query: "",
      ),
    );
  }

  void sortTracks(SortBy sortBy) {
    state = state.copyWith(sortBy: sortBy);
    unawaited(
      _refreshPresentationTracks(
        sourceTracks: tracks,
        sortBy: sortBy,
      ),
    );
  }

  /// Inverts the current visible order (visual only — does not change the
  /// underlying playlist/album). Persists across sort/search changes.
  void toggleReverse() {
    final reversed = !state.reversed;
    state = state.copyWith(
      reversed: reversed,
      presentationTracks: [...state.presentationTracks.reversed],
    );
  }
}

final presentationStateProvider = AutoDisposeNotifierProviderFamily<
    PresentationStateNotifier, PresentationState, Object>(
  () => PresentationStateNotifier(),
);
