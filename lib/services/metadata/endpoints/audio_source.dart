import 'package:hetu_script/hetu_script.dart';
import 'package:hetu_script/values.dart';
import 'package:spotube/models/metadata/metadata.dart';

/// Convert Hetu HTStruct/object to a plain Map for Freezed fromJson.
Map<String, dynamic> _hetuToMap(dynamic obj) {
  if (obj is Map<String, dynamic>) return obj;
  if (obj is HTStruct) return obj.toJson();
  throw ArgumentError(
      'Cannot convert ${obj.runtimeType} to Map<String, dynamic>');
}

class MetadataPluginAudioSourceEndpoint {
  final Hetu hetu;
  MetadataPluginAudioSourceEndpoint(this.hetu);

  HTInstance get hetuMetadataAudioSource =>
      (hetu.fetch("metadataPlugin") as HTInstance).memberGet("audioSource")
          as HTInstance;

  List<SpotubeAudioSourceContainerPreset> get supportedPresets {
    final raw = hetuMetadataAudioSource.memberGet("supportedPresets") as List;

    return raw
        .map((e) => SpotubeAudioSourceContainerPreset.fromJson(_hetuToMap(e)))
        .toList();
  }

  Future<List<SpotubeAudioSourceMatchObject>> matches(
    SpotubeFullTrackObject track,
  ) async {
    final raw = await hetuMetadataAudioSource
        .invoke("matches", positionalArgs: [track.toJson()]) as List;

    return raw
        .map((e) => SpotubeAudioSourceMatchObject.fromJson(_hetuToMap(e)))
        .toList();
  }

  Future<List<SpotubeAudioSourceStreamObject>> streams(
    SpotubeAudioSourceMatchObject match,
  ) async {
    final raw = await hetuMetadataAudioSource
        .invoke("streams", positionalArgs: [match.toJson()]) as List;

    return raw
        .map((e) => SpotubeAudioSourceStreamObject.fromJson(_hetuToMap(e)))
        .toList();
  }
}
