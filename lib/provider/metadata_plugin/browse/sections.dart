import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/utils/paginated.dart';

class MetadataPluginBrowseSectionsNotifier
    extends PaginatedAsyncNotifier<SpotubeBrowseSectionObject<Object>> {
  bool _isRecoverableError(Object error) {
    if (error is DioException) {
      return error.response?.statusCode == 401 ||
          error.response?.statusCode == 429;
    }

    final message = error.toString();
    return message.contains("401") || message.contains("429");
  }

  @override
  Future<SpotubePaginationResponseObject<SpotubeBrowseSectionObject<Object>>>
      fetch(
    int offset,
    int limit,
  ) async {
    try {
      return await (await metadataPlugin).browse.sections(
            limit: limit,
            offset: offset,
          );
    } catch (e) {
      if (_isRecoverableError(e) && state.value != null) {
        return state.value!;
      }
      if (_isRecoverableError(e)) {
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
    ref.watch(metadataPluginAuthenticatedProvider);
    return await fetch(0, 20);
  }
}

final metadataPluginBrowseSectionsProvider = AsyncNotifierProvider<
    MetadataPluginBrowseSectionsNotifier,
    SpotubePaginationResponseObject<SpotubeBrowseSectionObject<Object>>>(
  () => MetadataPluginBrowseSectionsNotifier(),
);
