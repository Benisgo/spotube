import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/logger/logger.dart';

class PlaylistCacheService {
  static Future<String> _getCacheDirectoryPath() async {
    final musicCacheDir = await UserPreferencesNotifier.getMusicCacheDir();
    final dir = Directory(join(musicCacheDir, ".playlist_cache"));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// Saves the user's saved playlists metadata to disk.
  static Future<void> saveUserPlaylists(
    SpotubePaginationResponseObject<SpotubeSimplePlaylistObject> data,
  ) async {
    try {
      final dirPath = await _getCacheDirectoryPath();
      final file = File(join(dirPath, "user_playlists.json"));
      await file.writeAsString(jsonEncode(data.toJson((item) => item.toJson())));
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
    }
  }

  /// Loads cached user playlists metadata from disk.
  static Future<SpotubePaginationResponseObject<SpotubeSimplePlaylistObject>?>
      loadUserPlaylists() async {
    try {
      final dirPath = await _getCacheDirectoryPath();
      final file = File(join(dirPath, "user_playlists.json"));
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        return SpotubePaginationResponseObject<SpotubeSimplePlaylistObject>.fromJson(
          json,
          (itemJson) => SpotubeSimplePlaylistObject.fromJson(itemJson),
        );
      }
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
    }
    return null;
  }

  /// Saves tracks of a specific playlist to disk.
  static Future<void> savePlaylistTracks(
    String playlistId,
    SpotubePaginationResponseObject<SpotubeFullTrackObject> data,
  ) async {
    try {
      final dirPath = await _getCacheDirectoryPath();
      final file = File(join(dirPath, "playlist_tracks_$playlistId.json"));
      await file.writeAsString(jsonEncode(data.toJson((item) => item.toJson())));
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
    }
  }

  /// Loads cached tracks for a playlist from disk.
  static Future<SpotubePaginationResponseObject<SpotubeFullTrackObject>?>
      loadPlaylistTracks(String playlistId) async {
    try {
      final dirPath = await _getCacheDirectoryPath();
      final file = File(join(dirPath, "playlist_tracks_$playlistId.json"));
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        return SpotubePaginationResponseObject<SpotubeFullTrackObject>.fromJson(
          json,
          (itemJson) => SpotubeFullTrackObject.fromJson(itemJson),
        );
      }
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
    }
    return null;
  }
}
