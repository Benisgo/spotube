import 'package:riverpod/riverpod.dart';
import 'package:dio/dio.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/utils/paginated.dart';

class MetadataPluginSavedArtistNotifier
    extends PaginatedAsyncNotifier<SpotubeFullArtistObject> {
  bool _isRecoverableLibraryError(Object error) {
    if (error is DioException) {
      return error.response?.statusCode == 401 ||
          error.response?.statusCode == 429;
    }

    final message = error.toString();
    return message.contains("401") || message.contains("429");
  }

  @override
  Future<SpotubePaginationResponseObject<SpotubeFullArtistObject>> fetch(
    int offset,
    int limit,
  ) async {
    try {
      final artists = await (await metadataPlugin).user.savedArtists(
            limit: limit,
            offset: offset,
          );

      return artists;
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
    return await fetch(0, 20);
  }

  Future<void> addFavorite(List<SpotubeFullArtistObject> artists) async {
    if (artists.isEmpty || state.value == null) return;
    final oldState = state.value;

    state = AsyncData(
      state.value!.copyWith(
        items: [
          ...artists,
          ...state.value!.items,
        ],
      ),
    );
    try {
      await (await metadataPlugin)
          .artist
          .save(artists.map((e) => e.id).toList());
    } catch (e) {
      state = AsyncData(oldState!);
      rethrow;
    }
  }

  Future<void> removeFavorite(List<SpotubeFullArtistObject> artists) async {
    if (artists.isEmpty || state.value == null) return;

    final oldState = state.value;

    final artistIds = artists.map((e) => e.id).toList();
    state = AsyncData(
      state.value!.copyWith(
        items: state.value!.items
            .where(
              (e) => artistIds.contains((e).id) == false,
            )
            .toList(),
      ),
    );

    try {
      await (await metadataPlugin).artist.unsave(artistIds);
    } catch (e) {
      state = AsyncData(oldState!);
      rethrow;
    }
  }
}

final metadataPluginSavedArtistsProvider = AsyncNotifierProvider<
    MetadataPluginSavedArtistNotifier,
    SpotubePaginationResponseObject<SpotubeFullArtistObject>>(
  () => MetadataPluginSavedArtistNotifier(),
);

final metadataPluginIsSavedArtistProvider =
    FutureProvider.autoDispose.family<bool, String>(
  (ref, artistId) async {
    final savedArtists =
        await ref.watch(metadataPluginSavedArtistsProvider.future);
    final savedArtistsNotifier =
        ref.read(metadataPluginSavedArtistsProvider.notifier);

    final allSavedArtists = savedArtists.hasMore
        ? await savedArtistsNotifier.fetchAll()
        : savedArtists.items;

    return allSavedArtists.any((element) => element.id == artistId);
  },
);
