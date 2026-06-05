import 'package:riverpod/riverpod.dart';
import 'package:dio/dio.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/utils/paginated.dart';

class MetadataPluginSavedAlbumNotifier
    extends PaginatedAsyncNotifier<SpotubeSimpleAlbumObject> {
  bool _isRecoverableLibraryError(Object error) {
    if (error is DioException) {
      return error.response?.statusCode == 401 ||
          error.response?.statusCode == 429;
    }

    final message = error.toString();
    return message.contains("401") || message.contains("429");
  }

  @override
  Future<SpotubePaginationResponseObject<SpotubeSimpleAlbumObject>> fetch(
    int offset,
    int limit,
  ) async {
    try {
      return await (await metadataPlugin).user.savedAlbums(
            limit: limit,
            offset: offset,
          );
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

  Future<void> addFavorite(List<SpotubeSimpleAlbumObject> albums) async {
    if (albums.isEmpty || state.value == null) return;
    final oldState = state.value;

    state = AsyncData(
      state.value!.copyWith(
        items: [
          ...albums,
          ...state.value!.items,
        ],
      ),
    );
    try {
      await (await metadataPlugin).album.save(albums.map((e) => e.id).toList());
    } catch (e) {
      state = AsyncData(oldState!);
      rethrow;
    }
  }

  Future<void> removeFavorite(List<SpotubeSimpleAlbumObject> albums) async {
    if (albums.isEmpty || state.value == null) return;

    final oldState = state.value;

    final albumIds = albums.map((e) => e.id).toList();
    state = AsyncData(
      state.value!.copyWith(
        items: state.value!.items
            .where(
              (e) => albumIds.contains((e).id) == false,
            )
            .toList(),
      ),
    );
    try {
      await (await metadataPlugin).album.unsave(albumIds);
    } catch (e) {
      state = AsyncData(oldState!);
      rethrow;
    }
  }
}

final metadataPluginSavedAlbumsProvider = AsyncNotifierProvider<
    MetadataPluginSavedAlbumNotifier,
    SpotubePaginationResponseObject<SpotubeSimpleAlbumObject>>(
  () => MetadataPluginSavedAlbumNotifier(),
);

final metadataPluginIsSavedAlbumProvider =
    FutureProvider.autoDispose.family<bool, String>(
  (ref, albumId) async {
    final savedAlbums =
        await ref.watch(metadataPluginSavedAlbumsProvider.future);
    final savedAlbumsNotifier =
        ref.read(metadataPluginSavedAlbumsProvider.notifier);
    final allSavedAlbums = savedAlbums.hasMore
        ? await savedAlbumsNotifier.fetchAll()
        : savedAlbums.items;

    return allSavedAlbums.any((element) => element.id == albumId);
  },
);
