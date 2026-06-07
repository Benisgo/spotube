import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/provider/metadata_plugin/utils/common.dart';
import 'package:spotube/provider/metadata_plugin/utils/paginated.dart';

class MetadataPluginSavedTracksNotifier
    extends AutoDisposePaginatedAsyncNotifier<SpotubeFullTrackObject> {
  MetadataPluginSavedTracksNotifier() : super();

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
    ref.cacheFor();

    await ref.watch(metadataPluginAuthenticatedProvider.future);
    return await fetch(0, 20);
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

    try {
      await (await metadataPlugin).track.save(tracks.map((e) => e.id).toList());
    } catch (e) {
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

    try {
      await (await metadataPlugin)
          .track
          .unsave(tracks.map((e) => e.id).toList());
    } catch (e) {
      state = AsyncData(oldState!);
      rethrow;
    }
  }
}

final metadataPluginSavedTracksProvider = AutoDisposeAsyncNotifierProvider<
    MetadataPluginSavedTracksNotifier,
    SpotubePaginationResponseObject<SpotubeFullTrackObject>>(
  () => MetadataPluginSavedTracksNotifier(),
);

final metadataPluginIsSavedTrackProvider =
    FutureProvider.autoDispose.family<bool, String>(
  (ref, trackId) async {
    final savedTracksState = ref.watch(metadataPluginSavedTracksProvider);
    final cachedTracks = savedTracksState.asData?.value.items;
    final cachedMatch = cachedTracks?.any((track) => track.id == trackId);
    if (cachedMatch == true) {
      return true;
    }

    final savedTracks = await ref.watch(metadataPluginSavedTracksProvider.future);
    if (!savedTracks.hasMore) {
      return savedTracks.items.any((track) => track.id == trackId);
    }

    final metadataPlugin = await ref.watch(metadataPluginProvider.future);
    if (metadataPlugin == null) {
      return false;
    }

    final result = await metadataPlugin.user.isSavedTracks([trackId]);
    return result.isNotEmpty && result.first;
  },
);
