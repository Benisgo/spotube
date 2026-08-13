part of 'metadata.dart';

@freezed
class SpotubeImageObject with _$SpotubeImageObject {
  factory SpotubeImageObject({
    required String url,
    int? width,
    int? height,
  }) = _SpotubeImageObject;

  factory SpotubeImageObject.fromJson(Map<String, dynamic> json) =>
      _$SpotubeImageObjectFromJson(json);
}

enum ImagePlaceholder {
  albumArt,
  artist,
  collection,
  online,
}

final placeholderUrlMap = {
  ImagePlaceholder.albumArt: Assets.images.albumPlaceholder.path,
  ImagePlaceholder.artist: Assets.images.userPlaceholder.path,
  ImagePlaceholder.collection: Assets.images.placeholder.path,
  ImagePlaceholder.online:
      "https://avatars.dicebear.com/api/bottts/${PrimitiveUtils.uuid.v4()}.png",
};

// Cache sorted image lists by list identity to avoid repeated O(n log n) sort
// on every build() call. Expando uses weak references — entries are GC'd when
// the source list is collected, so this never leaks memory.
final _sortedImageCache = Expando<List<SpotubeImageObject>>();

List<SpotubeImageObject>? _sortedImages(List<SpotubeImageObject>? images) {
  if (images == null || images.isEmpty) return images;
  return _sortedImageCache[images] ??= List.of(images)
    ..sort((a, b) {
      final widthCmp = (a.width ?? 0).compareTo(b.width ?? 0);
      if (widthCmp != 0) return widthCmp;
      return (a.height ?? 0).compareTo(b.height ?? 0);
    });
}

extension SpotubeImageExtensions on List<SpotubeImageObject>? {
  /// Returns the URL of the image at the specified index.
  String asUrlString({
    int index = 1,
    required ImagePlaceholder placeholder,
  }) {
    final sorted = _sortedImages(this);
    if (sorted == null || sorted.isEmpty) return placeholderUrlMap[placeholder]!;
    final clampedIndex = index > sorted.length - 1 ? sorted.length - 1 : index;
    return sorted[clampedIndex].url;
  }

  Uri asUri({
    int index = 1,
    required ImagePlaceholder placeholder,
  }) {
    final url = asUrlString(placeholder: placeholder, index: index);
    if (url.startsWith("http")) {
      return Uri.parse(url);
    }
    return Uri.file(url);
  }

  String smallest(ImagePlaceholder placeholder) {
    final sorted = _sortedImages(this);
    if (sorted == null || sorted.isEmpty) return placeholderUrlMap[placeholder]!;
    return sorted.first.url;
  }

  String from200PxTo300PxOrSmallestImage([
    ImagePlaceholder placeholder = ImagePlaceholder.albumArt,
  ]) {
    final sorted = _sortedImages(this);
    if (sorted == null || sorted.isEmpty) return placeholderUrlMap[placeholder]!;
    return sorted.firstWhere(
      (image) {
        final width = image.width ?? 0;
        final height = image.height ?? 0;
        return width >= 200 && height >= 200 && width <= 300 && height <= 300;
      },
      orElse: () => sorted.first,
    ).url;
  }
}

