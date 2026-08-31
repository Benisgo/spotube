part of 'metadata.dart';

@freezed
class SpotubeTrackObject with _$SpotubeTrackObject {
  factory SpotubeTrackObject.local({
    required String id,
    required String name,
    required String externalUri,
    @Default([]) List<SpotubeSimpleArtistObject> artists,
    required SpotubeSimpleAlbumObject album,
    required int durationMs,
    required String path,
    @Default(0) int fileSize,
    DateTime? dateAdded,
  }) = SpotubeLocalTrackObject;

  factory SpotubeTrackObject.full({
    required String id,
    required String name,
    required String externalUri,
    @Default([]) List<SpotubeSimpleArtistObject> artists,
    required SpotubeSimpleAlbumObject album,
    required int durationMs,
    required String isrc,
    required bool explicit,
    DateTime? addedAt,
  }) = SpotubeFullTrackObject;

  factory SpotubeTrackObject.localTrackFromFile(
    File file, {
    Metadata? metadata,
    String? art,
  }) {
    return SpotubeLocalTrackObject(
      id: file.absolute.path,
      name: metadata?.title ?? basenameWithoutExtension(file.path),
      externalUri: "file://${file.absolute.path}",
      artists: metadata?.artist?.split(",").map((a) {
            return SpotubeSimpleArtistObject(
              id: a.trim(),
              name: a.trim(),
              externalUri: "file://${file.absolute.path}",
            );
          }).toList() ??
          [
            SpotubeSimpleArtistObject(
              id: "unknown",
              name: "Unknown Artist",
              externalUri: "file://${file.absolute.path}",
            ),
          ],
      album: SpotubeSimpleAlbumObject(
        albumType: SpotubeAlbumType.album,
        id: metadata?.album ?? "unknown",
        name: metadata?.album ?? "Unknown Album",
        externalUri: "file://${file.absolute.path}",
        artists: [
          SpotubeSimpleArtistObject(
            id: metadata?.albumArtist ?? "unknown",
            name: metadata?.albumArtist ?? "Unknown Artist",
            externalUri: "file://${file.absolute.path}",
          ),
        ],
        releaseDate:
            metadata?.year != null ? "${metadata!.year}-01-01" : "1970-01-01",
        images: [
          if (art != null)
            SpotubeImageObject(
              url: art,
              width: 300,
              height: 300,
            ),
        ],
      ),
      durationMs: metadata?.durationMs?.toInt() ?? 0,
      path: file.path,
      fileSize: file.lengthSync(),
      dateAdded: file.lastModifiedSync(),
    );
  }

  factory SpotubeTrackObject.fromJson(Map<String, dynamic> json) =>
      _$SpotubeTrackObjectFromJson(
        json.containsKey("path")
            ? {...json, "runtimeType": "local"}
            : {
                ...json,
                if (json.containsKey("added_at") &&
                    !json.containsKey("addedAt"))
                  "addedAt": json["added_at"],
                "runtimeType": "full",
              },
      );
}

extension SpotubeTrackObjectAddedAtX on SpotubeTrackObject {
  DateTime? get addedAt => switch (this) {
        SpotubeFullTrackObject(:final addedAt) => addedAt,
        _ => null,
      };
}

extension AsMediaListSpotubeTrackObject on Iterable<SpotubeTrackObject> {
  List<SpotubeMedia> asMediaList({
    String? firstTrackDirectUrl,
    Map<String, String>? firstTrackDirectHeaders,
    SpotubeTrackObject? targetTrack,
    String? downloadLocation,
  }) {
    return map((track) {
      String? localPath;
      if (track is SpotubeFullTrackObject &&
          downloadLocation != null &&
          downloadLocation.isNotEmpty) {
        localPath = ServiceUtils.findDownloadedFile(
          downloadLocation,
          track.name,
          track.artists.map((a) => a.name).toList(),
        );
      }
      return SpotubeMedia(
        track,
        directUrl: track.id == targetTrack?.id ? firstTrackDirectUrl : null,
        httpHeaders:
            track.id == targetTrack?.id ? firstTrackDirectHeaders : null,
        localFilePath: localPath,
      );
    }).toList();
  }
}

extension ToMetadataSpotubeFullTrackObject on SpotubeFullTrackObject {
  Metadata toMetadata({
    required int fileLength,
    Uint8List? imageBytes,
    String? mimeType,
  }) {
    return Metadata(
      title: name,
      artist: artists.map((a) => a.name).join(", "),
      album: album.name,
      albumArtist: artists.map((a) => a.name).join(", "),
      year: album.releaseDate == null
          ? 1970
          : DateTime.tryParse(album.releaseDate!)?.year ??
              int.tryParse(album.releaseDate!) ??
              1970,
      durationMs: durationMs.toDouble(),
      fileSize: BigInt.from(fileLength),
      picture: imageBytes != null
          ? Picture(
              data: imageBytes,
              mimeType: mimeType ??
                  lookupMimeType("", headerBytes: imageBytes) ??
                  "image/jpeg",
            )
          : null,
    );
  }
}
