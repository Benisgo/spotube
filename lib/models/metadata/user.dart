part of 'metadata.dart';

Map<String, dynamic> _normalizeSpotubeUserJson(Map<String, dynamic> json) {
  final normalized = Map<String, dynamic>.from(json);
  normalized["id"] = (normalized["id"] ?? "").toString();
  normalized["name"] = (normalized["name"] ?? "").toString();
  normalized["externalUri"] = (normalized["externalUri"] ?? "").toString();
  return normalized;
}

@freezed
class SpotubeUserObject with _$SpotubeUserObject {
  factory SpotubeUserObject({
    required final String id,
    required final String name,
    @Default([]) final List<SpotubeImageObject> images,
    required final String externalUri,
  }) = _SpotubeUserObject;

  factory SpotubeUserObject.fromJson(Map<String, dynamic> json) =>
      _$SpotubeUserObjectFromJson(_normalizeSpotubeUserJson(json));
}
