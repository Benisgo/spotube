part of 'metadata.dart';

Map<String, dynamic> _normalizeSpotubePlaylistJson(Map<String, dynamic> json) {
  final normalized = Map<String, dynamic>.from(json);
  normalized["id"] = (normalized["id"] ?? "").toString();
  normalized["name"] = (normalized["name"] ?? "").toString();
  normalized["description"] = (normalized["description"] ?? "").toString();
  normalized["externalUri"] = (normalized["externalUri"] ?? "").toString();

  final owner = normalized["owner"];
  if (owner is Map) {
    normalized["owner"] = _normalizeSpotubeUserJson(
      owner.cast<String, dynamic>(),
    );
  }

  final collaborators = normalized["collaborators"];
  if (collaborators is List) {
    normalized["collaborators"] = collaborators
        .whereType<Map>()
        .map((item) => _normalizeSpotubeUserJson(item.cast<String, dynamic>()))
        .toList();
  }

  return normalized;
}

@freezed
class SpotubeFullPlaylistObject with _$SpotubeFullPlaylistObject {
  factory SpotubeFullPlaylistObject({
    required String id,
    required String name,
    required String description,
    required String externalUri,
    required SpotubeUserObject owner,
    @Default([]) List<SpotubeImageObject> images,
    @Default([]) List<SpotubeUserObject> collaborators,
    @Default(false) bool collaborative,
    @Default(false) bool public,
  }) = _SpotubeFullPlaylistObject;

  factory SpotubeFullPlaylistObject.fromJson(Map<String, dynamic> json) =>
      _$SpotubeFullPlaylistObjectFromJson(_normalizeSpotubePlaylistJson(json));
}

@freezed
class SpotubeSimplePlaylistObject with _$SpotubeSimplePlaylistObject {
  factory SpotubeSimplePlaylistObject({
    required String id,
    required String name,
    required String description,
    required String externalUri,
    required SpotubeUserObject owner,
    @Default([]) List<SpotubeImageObject> images,
  }) = _SpotubeSimplePlaylistObject;

  factory SpotubeSimplePlaylistObject.fromJson(Map<String, dynamic> json) =>
      _$SpotubeSimplePlaylistObjectFromJson(
          _normalizeSpotubePlaylistJson(json));
}
