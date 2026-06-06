import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotube/extensions/dio.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/services/kv_store/kv_store.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/utils/platform.dart';
import 'package:yt_dlp_dart/yt_dlp_dart.dart';

class YtDlpBinary {
  static const _downloadBaseUrl =
      "https://github.com/yt-dlp/yt-dlp/releases/latest/download";
  static Completer<bool>? _ensureCompleter;

  static String get fileName => kIsWindows ? "yt-dlp.exe" : "yt-dlp";

  static String get downloadUrl => "$_downloadBaseUrl/$fileName";

  static Future<Directory> get _binaryDirectory async {
    final supportDirectory = await getApplicationSupportDirectory();
    final directory = Directory(join(supportDirectory.path, "bin"));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  static Future<File> get managedBinaryFile async {
    final directory = await _binaryDirectory;
    return File(join(directory.path, fileName));
  }

  static Future<bool> hasManagedBinary() async {
    final binary = await managedBinaryFile;
    return binary.exists();
  }

  static Future<void> removeManagedBinary() async {
    final binary = await managedBinaryFile;
    if (await binary.exists()) {
      await binary.delete();
    }

    final tempBinary = File("${binary.path}.part");
    if (await tempBinary.exists()) {
      await tempBinary.delete();
    }
  }

  static Future<String?> _getCustomBinaryPath() async {
    final customPath =
        KVStoreService.getYoutubeEnginePath(YoutubeClientEngine.ytDlp);

    if (customPath == null || customPath.isEmpty) {
      return null;
    }

    if (await File(customPath).exists()) {
      return customPath;
    }

    return null;
  }

  static Future<String?> findInstalledBinaryPath() async {
    if (!kIsDesktop) return null;

    final customPath = await _getCustomBinaryPath();
    if (customPath != null) {
      return customPath;
    }

    final managedBinary = await managedBinaryFile;
    if (await managedBinary.exists()) {
      return managedBinary.path;
    }

    if (await YtDlp.instance.checkAvailableInPath()) {
      return fileName;
    }

    return null;
  }

  static Future<bool> configureExistingBinary() async {
    final binaryPath = await findInstalledBinaryPath();
    if (binaryPath == null) return false;

    try {
      await YtDlp.instance.setBinaryLocation(binaryPath);
      return true;
    } catch (error, stackTrace) {
      await AppLogger.reportError(
        error,
        stackTrace,
        "Failed to configure yt-dlp binary",
      );
      return false;
    }
  }

  static Future<void> _makeExecutable(File file) async {
    if (kIsWindows) return;

    final mode = await file.stat();
    const executableMask = 64 | 8 | 1; // owner/group/others executable bits
    final permissions = mode.mode | executableMask;

    await Process.run("chmod", [permissions.toRadixString(8), file.path]);
  }

  static Future<File> downloadManagedBinary({
    ProgressCallback? onReceiveProgress,
  }) async {
    final targetFile = await managedBinaryFile;
    final tempFile = File("${targetFile.path}.part");

    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    final dio = Dio();

    try {
      await dio.chunkDownload(
        downloadUrl,
        tempFile.path,
        deleteOnError: true,
        onReceiveProgress: onReceiveProgress,
      );

      await _makeExecutable(tempFile);

      if (await targetFile.exists()) {
        await targetFile.delete();
      }

      await tempFile.rename(targetFile.path);
      await YtDlp.instance.setBinaryLocation(targetFile.path);

      return targetFile;
    } catch (error, stackTrace) {
      await AppLogger.reportError(
        error,
        stackTrace,
        "Failed to download managed yt-dlp binary",
      );
      rethrow;
    } finally {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  static Future<bool> ensureAvailable({
    bool downloadIfMissing = true,
    ProgressCallback? onReceiveProgress,
  }) async {
    if (!kIsDesktop) return false;

    if (_ensureCompleter != null) {
      return _ensureCompleter!.future;
    }

    final completer = Completer<bool>();
    _ensureCompleter = completer;

    () async {
      try {
        if (await configureExistingBinary()) {
          completer.complete(true);
          return;
        }

        if (!downloadIfMissing) {
          completer.complete(false);
          return;
        }

        await downloadManagedBinary(onReceiveProgress: onReceiveProgress);
        completer.complete(true);
      } catch (_) {
        completer.complete(false);
      } finally {
        _ensureCompleter = null;
      }
    }();

    return completer.future;
  }
}
