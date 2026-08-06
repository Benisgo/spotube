import 'dart:async';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/provider/metadata_plugin/utils/family_paginated.dart';
import 'package:spotube/provider/metadata_plugin/utils/common.dart';
import 'package:spotube/services/playlist_cache/playlist_cache.dart';

class MetadataPluginPlaylistTracksNotifier
    extends AutoDisposeFamilyPaginatedAsyncNotifier<SpotubeFullTrackObject,
        String> {
  MetadataPluginPlaylistTracksNotifier() : super();

  bool _isRecoverablePlaylistError(Object error) {
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
      final tracks = await (await metadataPlugin).playlist.tracks(
            arg,
            offset: offset,
            limit: limit,
          );

      if (offset == 0) {
        unawaited(PlaylistCacheService.savePlaylistTracks(arg, tracks));
      }

      return tracks;
    } catch (e) {
      final cachedTracks = await PlaylistCacheService.loadPlaylistTracks(arg);
      if (cachedTracks != null && cachedTracks.items.isNotEmpty) {
        return cachedTracks;
      }

      if (_isRecoverablePlaylistError(e) && state.value != null) {
        return state.value!;
      }
      return SpotubePaginationResponseObject(
        limit: limit,
        nextOffset: null,
        total: 0,
        hasMore: false,
        items: [],
      );
    }
  }

  @override
  build(arg) async {
    ref.cacheFor();

    ref.watch(metadataPluginProvider);
    return await fetch(0, 20);
  }
}

final metadataPluginPlaylistTracksProvider =
    AutoDisposeAsyncNotifierProviderFamily<MetadataPluginPlaylistTracksNotifier,
        SpotubePaginationResponseObject<SpotubeFullTrackObject>, String>(
  () => MetadataPluginPlaylistTracksNotifier(),
);
