/// Normalizes raw Spotify track JSON onto the camelCase shape the Spotube
/// models read, so fields like `duration_ms`, `added_at` and album
/// `release_date` survive into `SpotubeFullTrackObject`.
///
/// Handles three shapes transparently:
/// - flat camelCase already produced by the plugin's converters (no-op),
/// - flat snake_case REST tracks (`duration_ms`, `release_date`, ...),
/// - playlist / saved-track wrappers `{added_at, track: {...}}` (unwrap the
///   inner track and carry the added date over as `addedAt`).
Map<String, dynamic> normalizeTrackMap(Map<dynamic, dynamic> raw) {
  var map = <String, dynamic>{
    for (final entry in raw.entries) '${entry.key}': entry.value,
  };

  // Playlist / saved-tracks wrapper: {added_at, track: {...}} — unwrap the
  // inner track and carry the added date over to the camelCase key the model
  // reads (addedAt). Only unwrap when the wrapper has no own id.
  final inner = map['track'];
  if (inner is Map && map['id'] == null) {
    final track = <String, dynamic>{
      for (final entry in inner.entries) '${entry.key}': entry.value,
    };
    if (map['added_at'] != null && track['addedAt'] == null) {
      track['addedAt'] = map['added_at'];
    }
    map = track;
  }

  if (map.containsKey('duration_ms') && !map.containsKey('durationMs')) {
    map['durationMs'] = map['duration_ms'];
  }
  if (map.containsKey('added_at') && !map.containsKey('addedAt')) {
    map['addedAt'] = map['added_at'];
  }
  if (map.containsKey('release_date') && !map.containsKey('releaseDate')) {
    map['releaseDate'] = map['release_date'];
  }

  final album = map['album'];
  if (album is Map) {
    final albumMap = <String, dynamic>{
      for (final entry in album.entries) '${entry.key}': entry.value,
    };
    if (albumMap.containsKey('release_date') &&
        !albumMap.containsKey('releaseDate')) {
      albumMap['releaseDate'] = albumMap['release_date'];
    }
    map['album'] = albumMap;
  }

  return map;
}
