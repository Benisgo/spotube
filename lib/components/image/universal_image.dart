import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:spotube/collections/assets.gen.dart';

class UniversalImage extends HookWidget {
  final String path;
  final double? height;
  final double? width;
  final double scale;
  final String? placeholder;
  final BoxFit? fit;

  /// When false, network images render without the FadeInImage cross-fade
  /// animation (no AnimationController/ticker). Use for small thumbnails that
  /// are built in bulk (e.g. track list rows) to keep scroll builds cheap.
  final bool fadeIn;
  const UniversalImage({
    required this.path,
    this.height,
    this.width,
    this.placeholder,
    this.fit,
    this.scale = 1,
    this.fadeIn = true,
    super.key,
  });

  static bool _isFile(String p) {
    if (p.startsWith("file://")) return true;
    if (p.startsWith("http") || p.startsWith("assets")) return false;
    if (p.length > 500) return false;
    try {
      return File(p).existsSync();
    } catch (_) {
      return false;
    }
  }

  static ImageProvider imageProvider(
    String path, {
    final double? height,
    final double? width,
    final double scale = 1,
  }) {
    if (path.startsWith("http")) {
      return CachedNetworkImageProvider(
        path,
        maxHeight: height?.toInt(),
        maxWidth: width?.toInt(),
        cacheKey: path,
        scale: scale,
      );
    } else if (path.startsWith("assets")) {
      return AssetImage(path);
    } else if (_isFile(path)) {
      final filePath =
          path.startsWith("file://") ? path.replaceFirst("file://", "") : path;
      return FileImage(File(filePath), scale: scale);
    }
    try {
      return MemoryImage(base64Decode(path), scale: scale);
    } catch (_) {
      return AssetImage(Assets.images.placeholder.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (path.startsWith("http")) {
      if (!fadeIn) {
        // Cheap path: no FadeInImage, no animation. Shows the placeholder
        // until the first decoded frame is ready, then swaps it in instantly.
        return Image(
          image: CachedNetworkImageProvider(
            path,
            maxHeight: height?.toInt(),
            maxWidth: width?.toInt(),
            cacheKey: path,
            scale: scale,
          ),
          width: width,
          height: height,
          filterQuality: FilterQuality.low,
          fit: fit,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded) return child;
            if (frame == null) {
              return Image.asset(
                placeholder ?? Assets.images.placeholder.path,
                width: width,
                height: height,
                cacheHeight: height?.toInt(),
                cacheWidth: width?.toInt(),
                filterQuality: FilterQuality.low,
                scale: scale,
              );
            }
            return child;
          },
          errorBuilder: (context, error, stackTrace) {
            return Image.asset(
              placeholder ?? Assets.images.placeholder.path,
              width: width,
              height: height,
              cacheHeight: height?.toInt(),
              cacheWidth: width?.toInt(),
              filterQuality: FilterQuality.low,
              scale: scale,
            );
          },
        );
      }
      return FadeInImage(
        image: CachedNetworkImageProvider(
          path,
          maxHeight: height?.toInt(),
          maxWidth: width?.toInt(),
          cacheKey: path,
          scale: scale,
        ),
        height: height,
        width: width,
        placeholder: AssetImage(placeholder ?? Assets.images.placeholder.path),
        imageErrorBuilder: (context, error, stackTrace) {
          return Image.asset(
            placeholder ?? Assets.images.placeholder.path,
            width: width,
            height: height,
            cacheHeight: height?.toInt(),
            cacheWidth: width?.toInt(),
            filterQuality: FilterQuality.low,
            scale: scale,
          );
        },
        filterQuality: FilterQuality.low,
        fit: fit,
      );
    } else if (path.startsWith("assets")) {
      return Image.asset(
        path,
        width: width,
        height: height,
        cacheHeight: height?.toInt(),
        cacheWidth: width?.toInt(),
        filterQuality: FilterQuality.low,
        scale: scale,
        fit: fit,
        errorBuilder: (context, error, stackTrace) {
          return Image.asset(
            placeholder ?? Assets.images.placeholder.path,
            width: width,
            height: height,
            cacheHeight: height?.toInt(),
            cacheWidth: width?.toInt(),
            filterQuality: FilterQuality.low,
            scale: scale,
          );
        },
      );
    } else if (_isFile(path)) {
      final filePath =
          path.startsWith("file://") ? path.replaceFirst("file://", "") : path;
      return Image.file(
        File(filePath),
        width: width,
        height: height,
        cacheHeight: height?.toInt(),
        cacheWidth: width?.toInt(),
        filterQuality: FilterQuality.low,
        scale: scale,
        fit: fit,
        errorBuilder: (context, error, stackTrace) {
          return Image.asset(
            placeholder ?? Assets.images.placeholder.path,
            width: width,
            height: height,
            cacheHeight: height?.toInt(),
            cacheWidth: width?.toInt(),
            filterQuality: FilterQuality.low,
            scale: scale,
          );
        },
      );
    }

    try {
      return Image.memory(
        base64Decode(path),
        width: width,
        height: height,
        cacheHeight: height?.toInt(),
        cacheWidth: width?.toInt(),
        filterQuality: FilterQuality.low,
        scale: scale,
        fit: fit,
        errorBuilder: (context, error, stackTrace) {
          return Image.asset(
            placeholder ?? Assets.images.placeholder.path,
            width: width,
            height: height,
            cacheHeight: height?.toInt(),
            cacheWidth: width?.toInt(),
            filterQuality: FilterQuality.low,
            scale: scale,
          );
        },
      );
    } catch (_) {
      return Image.asset(
        placeholder ?? Assets.images.placeholder.path,
        width: width,
        height: height,
        cacheHeight: height?.toInt(),
        cacheWidth: width?.toInt(),
        filterQuality: FilterQuality.low,
        scale: scale,
      );
    }
  }
}
