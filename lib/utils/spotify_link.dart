enum SpotifyContentType { track, album, playlist, artist }

class SpotifyLinkInfo {
  final SpotifyContentType type;
  final String id;
  const SpotifyLinkInfo({required this.type, required this.id});
}

SpotifyContentType? _parseContentType(String type) {
  switch (type.toLowerCase()) {
    case 'track':
      return SpotifyContentType.track;
    case 'album':
      return SpotifyContentType.album;
    case 'playlist':
      return SpotifyContentType.playlist;
    case 'artist':
      return SpotifyContentType.artist;
    default:
      return null;
  }
}

SpotifyLinkInfo? _parseSpotifyUri(String path) {
  final parts = path.split(':');
  if (parts.length < 2) return null;

  // Handle legacy spotify:user:username:playlist:id format
  if (parts.length >= 4 && parts[0] == 'user') {
    final type = _parseContentType(parts[2]);
    if (type == null) return null;
    return SpotifyLinkInfo(type: type, id: parts[3]);
  }

  final type = _parseContentType(parts[0]);
  if (type == null) return null;

  return SpotifyLinkInfo(type: type, id: parts[1]);
}

SpotifyLinkInfo? _parseSpotifyWebUrl(String path) {
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();

  int startIndex = 0;
  if (segments.isNotEmpty && segments[0].startsWith('intl-')) {
    startIndex = 1;
  }

  if (segments.length - startIndex < 2) return null;

  final type = _parseContentType(segments[startIndex]);
  if (type == null) return null;

  return SpotifyLinkInfo(type: type, id: segments[startIndex + 1]);
}

SpotifyLinkInfo? parseSpotifyLink(String uriString) {
  final uri = Uri.tryParse(uriString);
  if (uri == null) return null;

  if (uri.scheme == 'spotify') {
    // Handle spotify://track/id format (with double slash and forward slash)
    if (uri.host.isNotEmpty) {
      final type = _parseContentType(uri.host);
      if (type != null) {
        final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
        if (id != null && id.isNotEmpty) {
          return SpotifyLinkInfo(type: type, id: id);
        }
      }
    }
    // Handle spotify:track:id format (with colons only)
    return _parseSpotifyUri(uri.path);
  }

  if (uri.scheme == 'https' && uri.host == 'open.spotify.com') {
    return _parseSpotifyWebUrl(uri.path);
  }

  return null;
}
