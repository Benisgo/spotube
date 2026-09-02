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
      final cacheH = height != null ? (height * 2).round() : 512;
      final cacheW = width != null ? (width * 2).round() : 512;
      return CachedNetworkImageProvider(
        path,
        maxHeight: cacheH,
        maxWidth: cacheW,
        cacheKey: path,
        scale: scale,
      );
    } else if (path.startsWith("assets")) {
      final cacheH = height != null ? (height * 2).round() : null;
      final cacheW = width != null ? (width * 2).round() : null;
      return ResizeImage.resizeIfNeeded(
        cacheW,
        cacheH,
        AssetImage(path),
      );
    } else if (_isFile(path)) {
      final filePath =
          path.startsWith("file://") ? path.replaceFirst("file://", "") : path;
      final cacheH = height != null ? (height * 2).round() : null;
      final cacheW = width != null ? (width * 2).round() : null;
      return ResizeImage.resizeIfNeeded(
        cacheW,
        cacheH,
        FileImage(File(filePath), scale: scale),
      );
    }
    try {
      return MemoryImage(base64Decode(path), scale: scale);
    } catch (_) {
      return AssetImage(Assets.images.placeholder.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cacheW = width != null ? (width! * 2).round() : 512;
    final cacheH = height != null ? (height! * 2).round() : 512;

    if (path.startsWith("http")) {
      return CachedNetworkImage(
        imageUrl: path,
        width: width,
        height: height,
        fit: fit,
        memCacheWidth: cacheW,
        memCacheHeight: cacheH,
        maxWidthDiskCache: 1000,
        maxHeightDiskCache: 1000,
        filterQuality: FilterQuality.low,
        fadeInDuration:
            fadeIn ? const Duration(milliseconds: 150) : Duration.zero,
        fadeOutDuration:
            fadeIn ? const Duration(milliseconds: 150) : Duration.zero,
        placeholder: (context, url) => Image.asset(
          placeholder ?? Assets.images.placeholder.path,
          width: width,
          height: height,
          cacheHeight: cacheH,
          cacheWidth: cacheW,
          filterQuality: FilterQuality.low,
          fit: fit,
        ),
        errorWidget: (context, url, error) => Image.asset(
          placeholder ?? Assets.images.placeholder.path,
          width: width,
          height: height,
          cacheHeight: cacheH,
          cacheWidth: cacheW,
          filterQuality: FilterQuality.low,
          fit: fit,
        ),
      );
    } else if (path.startsWith("assets")) {
      return Image.asset(
        path,
        width: width,
        height: height,
        cacheHeight: cacheH,
        cacheWidth: cacheW,
        filterQuality: FilterQuality.low,
        scale: scale,
        fit: fit,
        errorBuilder: (context, error, stackTrace) {
          return Image.asset(
            placeholder ?? Assets.images.placeholder.path,
            width: width,
            height: height,
            cacheHeight: cacheH,
            cacheWidth: cacheW,
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
        cacheHeight: cacheH,
        cacheWidth: cacheW,
        filterQuality: FilterQuality.low,
        scale: scale,
        fit: fit,
        errorBuilder: (context, error, stackTrace) {
          return Image.asset(
            placeholder ?? Assets.images.placeholder.path,
            width: width,
            height: height,
            cacheHeight: cacheH,
            cacheWidth: cacheW,
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
        cacheHeight: cacheH,
        cacheWidth: cacheW,
        filterQuality: FilterQuality.low,
        scale: scale,
        fit: fit,
        errorBuilder: (context, error, stackTrace) {
          return Image.asset(
            placeholder ?? Assets.images.placeholder.path,
            width: width,
            height: height,
            cacheHeight: cacheH,
            cacheWidth: cacheW,
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
        cacheHeight: cacheH,
        cacheWidth: cacheW,
        filterQuality: FilterQuality.low,
        scale: scale,
      );
    }
  }
}
