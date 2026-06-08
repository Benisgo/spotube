import 'dart:math';

import 'package:dio/dio.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/utils/common.dart';
import 'package:spotube/provider/metadata_plugin/utils/paginated.dart';
import 'package:spotube/services/logger/logger.dart';

final Map<String, bool> _savedTrackMembershipCache = {};

final metadataPluginSavedTracksFetchProgressProvider =
    StateProvider<double?>((ref) => null);

void resetSavedTracksFetchProgress(WidgetRef ref) {
  ref.read(metadataPluginSavedTracksFetchProgressProvider.notifier).state = null;
}

bool? getSavedTrackMembershipSnapshot(String trackId) {
  return _savedTrackMembershipCache[trackId];
}

class MetadataPluginSavedTracksNotifier
    extends PaginatedAsyncNotifier<SpotubeFullTrackObject> {
  MetadataPluginSavedTracksNotifier() : super();
  static const _parallelFetchBatchSize = 4;
  final Map<String, Future<bool>> _inFlightLookups = {};
  Future<List<SpotubeFullTrackObject>>? _inFlightFetchAll;

  List<SpotubeFullTrackObject> _mergeUniqueTracks(
    Iterable<SpotubeFullTrackObject> existing,
    Iterable<SpotubeFullTrackObject> incoming,
  ) {
    final merged = <String, SpotubeFullTrackObject>{};

    for (final track in existing) {
      merged[track.id] = track;
    }

    for (final track in incoming) {
      merged[track.id] = track;
    }

    return merged.values.toList();
  }

  bool _isRecoverableLibraryError(Object error) {
    if (error is DioException) {
      return error.response?.statusCode == 401 ||
          error.response?.statusCode == 429;
    }

    final message = error.toString();
    return message.contains("401") || message.contains("429");
  }

  @override
  fetch(offset, limit) async {
    try {
      final tracks = await (await metadataPlugin).user.savedTracks(
            offset: offset,
            limit: limit,
          );

      return tracks;
    } catch (e) {
      if (_isRecoverableLibraryError(e) && state.value != null) {
        return state.value!;
      }
      if (_isRecoverableLibraryError(e)) {
        return SpotubePaginationResponseObject(
          limit: limit,
          nextOffset: null,
          total: 0,
          hasMore: false,
          items: [],
        );
      }
      rethrow;
    }
  }

  @override
  build() async {
    await ref.watch(metadataPluginAuthenticatedProvider.future);
    final response = await fetch(0, 20);
    for (final track in response.items) {
      _savedTrackMembershipCache[track.id] = true;
    }
    return response;
  }

  Future<void> addFavorite(List<SpotubeTrackObject> tracks) async {
    if (state.value == null) {
      return;
    }

    final oldState = state.value;
    state = AsyncData(
      state.value!.copyWith(
        items: [
          ...tracks.whereType<SpotubeFullTrackObject>(),
          ...state.value!.items
        ],
      ),
    );
    for (final track in tracks) {
      _savedTrackMembershipCache[track.id] = true;
    }

    try {
      await (await metadataPlugin).track.save(tracks.map((e) => e.id).toList());
    } catch (e) {
      for (final track in tracks) {
        _savedTrackMembershipCache.remove(track.id);
      }
      state = AsyncData(oldState!);
      rethrow;
    }
  }

  Future<void> removeFavorite(List<SpotubeTrackObject> tracks) async {
    if (state.value == null) {
      return;
    }

    final oldState = state.value;
    state = AsyncData(
      state.value!.copyWith(
        items: state.value!.items
            .where(
              (savedTrack) => !tracks.any((track) => track.id == savedTrack.id),
            )
            .toList(),
      ),
    );
    for (final track in tracks) {
      _savedTrackMembershipCache[track.id] = false;
    }

    try {
      await (await metadataPlugin)
          .track
          .unsave(tracks.map((e) => e.id).toList());
    } catch (e) {
      for (final track in tracks) {
        _savedTrackMembershipCache.remove(track.id);
      }
      state = AsyncData(oldState!);
      rethrow;
    }
  }

  Future<bool> containsTrackId(String trackId) async {
    final cachedMembership = _savedTrackMembershipCache[trackId];
    if (cachedMembership != null) {
      return cachedMembership;
    }

    final cachedItems = state.value?.items ?? const <SpotubeFullTrackObject>[];
    if (cachedItems.any((track) => track.id == trackId)) {
      _savedTrackMembershipCache[trackId] = true;
      return true;
    }

    final activeLookup = _inFlightLookups[trackId];
    if (activeLookup != null) {
      return activeLookup;
    }

    final future = _containsTrackIdInternal(trackId);
    _inFlightLookups[trackId] = future;

    try {
      return await future;
    } finally {
      final current = _inFlightLookups[trackId];
      if (identical(current, future)) {
        _inFlightLookups.remove(trackId);
      }
    }
  }

  Future<bool> _containsTrackIdInternal(String trackId) async {
    final currentState = state.value;
    if (currentState == null) {
      final loaded = await future;
      if (loaded.items.any((track) => track.id == trackId)) {
        _savedTrackMembershipCache[trackId] = true;
        return true;
      }
      if (!loaded.hasMore) {
        _savedTrackMembershipCache[trackId] = false;
        return false;
      }
    } else if (!currentState.hasMore) {
      final contains = currentState.items.any((track) => track.id == trackId);
      _savedTrackMembershipCache[trackId] = contains;
      return contains;
    }

    while (state.value?.hasMore == true) {
      final previousLength = state.value?.items.length ?? 0;
      await fetchMore();
      final latestItems =
          state.value?.items ?? const <SpotubeFullTrackObject>[];
      if (latestItems.any((track) => track.id == trackId)) {
        _savedTrackMembershipCache[trackId] = true;
        return true;
      }

      final didAdvance = latestItems.length > previousLength;
      if (!didAdvance) {
        break;
      }
    }

    final contains =
        state.value?.items.any((track) => track.id == trackId) ?? false;
    _savedTrackMembershipCache[trackId] = contains;
    return contains;
  }

  @override
  Future<void> fetchMore() async {
    if (state.value == null || !state.value!.hasMore) return;

    final oldState = state.value;
    try {
      state = AsyncLoadingNext(state.asData!.value);

      final newState = await fetch(
        state.value!.nextOffset!,
        state.value!.limit,
      );

      final mergedItems = _mergeUniqueTracks(
        oldState?.items ?? const <SpotubeFullTrackObject>[],
        newState.items,
      );

      for (final track in mergedItems) {
        _savedTrackMembershipCache[track.id] = true;
      }

      state = AsyncData(newState.copyWith(items: mergedItems));
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      state = AsyncData(oldState!);
    }
  }

  @override
  Future<List<SpotubeFullTrackObject>> fetchAll() {
    final activeFetchAll = _inFlightFetchAll;
    if (activeFetchAll != null) return activeFetchAll;

    final currentValue = state.value;
    if (currentValue != null && currentValue.total > 0) {
      ref.read(metadataPluginSavedTracksFetchProgressProvider.notifier).state =
          currentValue.items.length / currentValue.total;
    }

    final future = _fetchAllInternal();
    _inFlightFetchAll = future;

    future.whenComplete(() {
      ref.read(metadataPluginSavedTracksFetchProgressProvider.notifier).state =
          null;
      if (identical(_inFlightFetchAll, future)) {
        _inFlightFetchAll = null;
      }
    });

    return future;
  }

  Future<SpotubePaginationResponseObject<SpotubeFullTrackObject>>
      _fetchFullLibraryPage(
    int offset,
    int limit,
  ) async {
    return fetch(offset, max(limit, 100))
        .catchError((e) => fetch(offset, max(limit, 50)))
        .catchError((e) => fetch(offset, limit))
        .catchError((e) async {
      await Future.delayed(const Duration(milliseconds: 500));
      return fetch(offset, limit);
    });
  }

  Future<List<SpotubeFullTrackObject>> _fetchAllInternal() async {
    if (state.value == null) return [];
    if (!state.value!.hasMore) {
      return _mergeUniqueTracks(
        const <SpotubeFullTrackObject>[],
        state.value!.items,
      );
    }

    var currentState = state.value!;
    final pageLimit = max(currentState.limit, 100);
    final total = currentState.total;
    final fetchedOffsets = <int>{0};
    var nextOffset = currentState.nextOffset;
    var actualPageSize = pageLimit;

    if (nextOffset != null && nextOffset < total) {
      final firstPage = await _fetchFullLibraryPage(nextOffset, pageLimit);
      final mergedItems = _mergeUniqueTracks(
        currentState.items,
        firstPage.items,
      );

      for (final track in mergedItems) {
        _savedTrackMembershipCache[track.id] = true;
      }

      currentState = firstPage.copyWith(items: mergedItems);
      if (currentState.total > 0) {
        ref.read(metadataPluginSavedTracksFetchProgressProvider.notifier).state =
            currentState.items.length / currentState.total;
      }
      actualPageSize =
          max(firstPage.items.length, firstPage.limit == 0 ? 1 : firstPage.limit);
      fetchedOffsets.add(nextOffset);
      nextOffset = firstPage.hasMore ? nextOffset + actualPageSize : null;
    }

    while (nextOffset != null && nextOffset < total) {
      final batchOffsets = <int>[];
      var candidateOffset = nextOffset;

      while (batchOffsets.length < _parallelFetchBatchSize &&
          candidateOffset < total) {
        if (fetchedOffsets.add(candidateOffset)) {
          batchOffsets.add(candidateOffset);
        }
        candidateOffset += actualPageSize;
      }

      if (batchOffsets.isEmpty) {
        break;
      }

      final pages = await Future.wait(
        batchOffsets
            .map((offset) => _fetchFullLibraryPage(offset, pageLimit))
            .toList(),
      );

      var didAdvance = false;
      for (final newState in pages) {
        final previousLength = currentState.items.length;
        final previousNextOffset = currentState.nextOffset;
        final mergedItems = _mergeUniqueTracks(
          currentState.items,
          newState.items,
        );

        didAdvance = didAdvance ||
            mergedItems.length > previousLength ||
            newState.nextOffset != previousNextOffset;

        for (final track in mergedItems) {
          _savedTrackMembershipCache[track.id] = true;
        }

        currentState = newState.copyWith(items: mergedItems);
        if (currentState.total > 0) {
          ref
              .read(metadataPluginSavedTracksFetchProgressProvider.notifier)
              .state = currentState.items.length / currentState.total;
        }
      }

      nextOffset =
          currentState.hasMore ? batchOffsets.last + actualPageSize : null;

      if (!didAdvance) {
        break;
      }
    }

    state = AsyncData(
      currentState.copyWith(
        items: currentState.items,
        hasMore: false,
        nextOffset: null,
      ),
    );
    return state.value!.items.cast<SpotubeFullTrackObject>();
  }
}

final metadataPluginSavedTracksProvider = AsyncNotifierProvider<
    MetadataPluginSavedTracksNotifier,
    SpotubePaginationResponseObject<SpotubeFullTrackObject>>(
  () => MetadataPluginSavedTracksNotifier(),
);

final metadataPluginIsSavedTrackProvider = FutureProvider.family<bool, String>(
  (ref, trackId) async {
    final cachedMembership = _savedTrackMembershipCache[trackId];
    if (cachedMembership != null) {
      return cachedMembership;
    }

    final savedTracksState = ref.watch(metadataPluginSavedTracksProvider);
    final savedTracksNotifier =
        ref.watch(metadataPluginSavedTracksProvider.notifier);
    final cachedTracks = savedTracksState.asData?.value.items;
    final cachedMatch = cachedTracks?.any((track) => track.id == trackId);
    if (cachedMatch == true) {
      _savedTrackMembershipCache[trackId] = true;
      return true;
    }

    final savedTracks =
        await ref.watch(metadataPluginSavedTracksProvider.future);
    if (!savedTracks.hasMore) {
      final contains = savedTracks.items.any((track) => track.id == trackId);
      _savedTrackMembershipCache[trackId] = contains;
      return contains;
    }

    return savedTracksNotifier.containsTrackId(trackId);
  },
);
