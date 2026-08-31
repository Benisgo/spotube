import 'dart:math';
import 'dart:typed_data';

import 'dart:io';

import 'package:path/path.dart' show basenameWithoutExtension;
import 'package:dio/dio.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'package:shadcn_flutter/shadcn_flutter.dart' hide Element;
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/pages/library/user_local_tracks/user_local_tracks.dart';
import 'package:spotube/modules/root/update_dialog.dart';

import 'package:spotube/provider/database/database.dart';
import 'package:spotube/services/dio/dio.dart';
import 'package:spotube/services/logger/logger.dart';

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:spotube/collections/env.dart';

import 'package:version/version.dart';

enum UserAgentDevice {
  desktop,
  mobile,
}

abstract class ServiceUtils {
  static bool _shouldUseNightlyUpdateChannel(PackageInfo packageInfo) {
    final version = packageInfo.version.toLowerCase();

    if (version.contains("nightly") ||
        version.contains("dev") ||
        version.contains("pre")) {
      return true;
    }

    return Env.releaseChannel == ReleaseChannel.nightly &&
        packageInfo.version == "Unknown";
  }

  static final _englishMatcherRegex = RegExp(
    "^[a-zA-Z0-9\\s!\"#\$%&\\'()*+,-.\\/:;<=>?@\\[\\]^_`{|}~]*\$",
  );
  static bool onlyContainsEnglish(String text) {
    return _englishMatcherRegex.hasMatch(text);
  }

  static String clearArtistsOfTitle(String title, List<String> artists) {
    return title
        .replaceAll(RegExp(artists.join("|"), caseSensitive: false), "")
        .trim();
  }

  static String getTitle(
    String title, {
    List<String> artists = const [],
    bool onlyCleanArtist = false,
  }) {
    final match = RegExp(r"(?<=\().+?(?=\))").firstMatch(title)?.group(0);
    final artistInBracket =
        artists.any((artist) => match?.contains(artist) ?? false);

    if (artistInBracket) {
      title = title.replaceAll(
        RegExp(" *\\([^)]*\\) *"),
        '',
      );
    }

    title = clearArtistsOfTitle(title, artists);
    if (onlyCleanArtist) {
      artists = [];
    }

    return "$title ${artists.map((e) => e.replaceAll(",", " ")).join(", ")}"
        .replaceAll(RegExp(r"\s*\[[^\]]*]"), ' ')
        .replaceAll(RegExp(r"\sfeat\.|\sft\.", caseSensitive: false), ' ')
        .replaceAll(RegExp(r"\s+"), ' ')
        .trim();
  }

  static DateTime parseSpotifyAlbumDate(SpotubeSimpleAlbumObject? album) {
    if (album == null ||
        album.releaseDate == null ||
        album.releaseDate!.isEmpty) {
      return DateTime(1975);
    }
    final raw = album.releaseDate!;
    if (raw.length == 4) {
      return DateTime(int.tryParse(raw) ?? 1975);
    }
    return DateTime.tryParse(raw) ?? DateTime(1975);
  }

  static List<T> sortTracks<T extends SpotubeTrackObject>(
      List<T> tracks, SortBy sortBy) {
    if (sortBy == SortBy.none) return tracks;
    return List<T>.from(tracks)
      ..sort((a, b) {
        switch (sortBy) {
          case SortBy.ascending:
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          case SortBy.descending:
            return b.name.toLowerCase().compareTo(a.name.toLowerCase());
          case SortBy.newest:
            final aDate = parseSpotifyAlbumDate(a.album);
            final bDate = parseSpotifyAlbumDate(b.album);
            return bDate.compareTo(aDate);
          case SortBy.oldest:
            final aDate = parseSpotifyAlbumDate(a.album);
            final bDate = parseSpotifyAlbumDate(b.album);
            return aDate.compareTo(bDate);
          case SortBy.duration:
            return a.durationMs.compareTo(b.durationMs);
          case SortBy.artist:
            return a.artists.first.name
                .toLowerCase()
                .compareTo(b.artists.first.name.toLowerCase());
          case SortBy.album:
            return a.album.name
                .toLowerCase()
                .compareTo(b.album.name.toLowerCase());
          default:
            return 0;
        }
      });
  }

  static Future<void> checkForUpdates(
    BuildContext context,
    WidgetRef ref,
  ) async {
    if (!Env.enableUpdateChecker) return;
    final database = ref.read(databaseProvider);
    final checkUpdate = await (database.selectOnly(database.preferencesTable)
          ..addColumns([database.preferencesTable.checkUpdate])
          ..where(database.preferencesTable.id.equals(0)))
        .map((row) => row.read(database.preferencesTable.checkUpdate))
        .getSingleOrNull();

    if (checkUpdate == false) return;
    final packageInfo = await PackageInfo.fromPlatform();

    try {
      if (_shouldUseNightlyUpdateChannel(packageInfo)) {
        final value = await globalDio.getUri(
          Uri.parse(
            "https://api.github.com/repos/${Env.updateRepository}/actions/workflows/spotube-release-binary.yml/runs?status=success&per_page=1",
          ),
          options: Options(
            responseType: ResponseType.json,
          ),
        );

        final buildNum = value.data["workflow_runs"][0]["run_number"] as int;

        if (buildNum <= int.parse(packageInfo.buildNumber) ||
            !context.mounted) {
          return;
        }

        await showDialog(
          context: context,
          barrierDismissible: true,
          barrierColor: Colors.black.withAlpha(66),
          builder: (context) {
            return RootAppUpdateDialog.nightly(nightlyBuildNum: buildNum);
          },
        );
      } else {
        final value = await globalDio.getUri(
          Uri.parse(
            "https://api.github.com/repos/${Env.updateRepository}/releases/latest",
          ),
        );
        final tagName = (value.data["tag_name"] as String).replaceAll("v", "");
        final currentVersion = packageInfo.version == "Unknown"
            ? null
            : Version.parse(packageInfo.version);
        final latestVersion =
            tagName == "nightly" ? null : Version.parse(tagName);

        if (currentVersion == null ||
            latestVersion == null ||
            (latestVersion.isPreRelease && !currentVersion.isPreRelease) ||
            (!latestVersion.isPreRelease && currentVersion.isPreRelease)) {
          return;
        }

        if (latestVersion <= currentVersion || !context.mounted) return;

        showDialog(
          context: context,
          barrierDismissible: true,
          barrierColor: Colors.black.withAlpha(66),
          builder: (context) {
            return RootAppUpdateDialog(version: latestVersion);
          },
        );
      }
    } catch (error, stackTrace) {
      await AppLogger.reportError(
        error,
        stackTrace,
        "App update check failed",
      );
    }
  }

  static Future<Uint8List?> downloadImage(
    String imageUrl,
  ) async {
    try {
      final fileStream = DefaultCacheManager().getImageFile(imageUrl);

      final bytes = List<int>.empty(growable: true);

      await for (final data in fileStream) {
        if (data is FileInfo) {
          bytes.addAll(data.file.readAsBytesSync());
          break;
        }
      }

      return Uint8List.fromList(bytes);
    } catch (e, stackTrace) {
      AppLogger.reportError(e, stackTrace);
      return null;
    }
  }

  static int randomNumber(int min, int max) {
    return min + Random().nextInt(max - min);
  }

  static String randomUserAgent(UserAgentDevice type) {
    if (type == UserAgentDevice.desktop) {
      return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_${randomNumber(11, 15)}_${randomNumber(4, 9)}) AppleWebKit/${randomNumber(530, 537)}.${randomNumber(30, 37)} (KHTML, like Gecko) Chrome/${randomNumber(80, 105)}.0.${randomNumber(3000, 4500)}.${randomNumber(60, 125)} Safari/${randomNumber(530, 537)}.${randomNumber(30, 36)}";
    } else {
      return "Mozilla/5.0 (Linux; Android ${randomNumber(8, 13)}) AppleWebKit/${randomNumber(530, 537)}.${randomNumber(30, 36)} (KHTML, like Gecko) Chrome/${randomNumber(101, 116)}.0.${randomNumber(3000, 6000)}.${randomNumber(60, 125)} Mobile Safari/${randomNumber(530, 537)}.${randomNumber(30, 36)}";
    }
  }

  /// Check if a downloaded file exists for the given track in the download directory.
  /// Returns the file path if found, null otherwise.
  static String? findDownloadedFile(
    String downloadDir,
    String trackName,
    List<String> artists,
  ) {
    final dir = Directory(downloadDir);
    if (!dir.existsSync()) return null;

    final baseName = sanitizeFilename(
      '$trackName - ${artists.join(", ")}',
    );

    final entries = dir.listSync(followLinks: false);
    for (final entry in entries) {
      if (entry is File) {
        final nameWithoutExt = basenameWithoutExtension(entry.path);
        if (nameWithoutExt == baseName) {
          return entry.path;
        }
      }
    }
    return null;
  }

  static String sanitizeFilename(String input, {String replacement = ''}) {
    final result = input
        // illegalRe
        .replaceAll(
          RegExp(r'[\/\?<>\\:\*\|"]'),
          replacement,
        )
        // controlRe
        .replaceAll(
          RegExp(
            r'[\x00-\x1f\x80-\x9f]',
          ),
          replacement,
        )
        // reservedRe
        .replaceFirst(
          RegExp(r'^\.+$'),
          replacement,
        )
        // windowsReservedRe
        .replaceFirst(
          RegExp(
            r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$',
            caseSensitive: false,
          ),
          replacement,
        )
        // windowsTrailingRe
        .replaceFirst(RegExp(r'[\. ]+$'), replacement);

    return result.length > 255 ? result.substring(0, 255) : result;
  }
}
