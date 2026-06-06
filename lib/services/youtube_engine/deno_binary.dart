import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotube/extensions/dio.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/utils/platform.dart';

class DenoBinary {
  static const _downloadBaseUrl =
      "https://github.com/denoland/deno/releases/latest/download";
  static Completer<bool>? _ensureCompleter;

  static bool get isAvailableForPlatform => kIsDesktop;

  static String get fileName => kIsWindows ? "deno.exe" : "deno";

  static String get archiveFileName => switch ((Platform.operatingSystem, ffi.Abi.current())) {
        ("windows", ffi.Abi.windowsX64) => "deno-x86_64-pc-windows-msvc.zip",
        ("windows", ffi.Abi.windowsArm64) => "deno-aarch64-pc-windows-msvc.zip",
        ("macos", ffi.Abi.macosX64) => "deno-x86_64-apple-darwin.zip",
        ("macos", ffi.Abi.macosArm64) => "deno-aarch64-apple-darwin.zip",
        ("linux", ffi.Abi.linuxX64) => "deno-x86_64-unknown-linux-gnu.zip",
        ("linux", ffi.Abi.linuxArm64) => "deno-aarch64-unknown-linux-gnu.zip",
        _ => throw UnsupportedError(
            "Managed Deno download is not supported on ${Platform.operatingSystem}/${ffi.Abi.current()}",
          ),
      };

  static String get downloadUrl => "$_downloadBaseUrl/$archiveFileName";

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

    final archiveFile = File("${binary.path}.zip.part");
    if (await archiveFile.exists()) {
      await archiveFile.delete();
    }
  }

  static Future<String?> findInstalledBinaryPath() async {
    if (!isAvailableForPlatform) return null;

    final managedBinary = await managedBinaryFile;
    if (await managedBinary.exists()) {
      return managedBinary.path;
    }

    try {
      final result = await Process.run("deno", ["--version"]);
      if (result.exitCode == 0) {
        return "deno";
      }
    } catch (_) {}

    return null;
  }

  static Future<bool> isInstalled() async {
    return await findInstalledBinaryPath() != null;
  }

  static Future<void> _makeExecutable(File file) async {
    if (kIsWindows) return;

    final mode = await file.stat();
    const executableMask = 64 | 8 | 1;
    final permissions = mode.mode | executableMask;

    await Process.run("chmod", [permissions.toRadixString(8), file.path]);
  }

  static Future<File> downloadManagedBinary({
    ProgressCallback? onReceiveProgress,
  }) async {
    final targetFile = await managedBinaryFile;
    final archiveFile = File("${targetFile.path}.zip.part");

    if (await archiveFile.exists()) {
      await archiveFile.delete();
    }

    final dio = Dio();

    try {
      await dio.chunkDownload(
        downloadUrl,
        archiveFile.path,
        deleteOnError: true,
        onReceiveProgress: onReceiveProgress,
      );

      final bytes = await archiveFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final denoEntry = archive.files.firstWhere(
        (file) => file.name == fileName,
        orElse: () => throw Exception(
          "Managed Deno archive did not contain $fileName",
        ),
      );

      if (await targetFile.exists()) {
        await targetFile.delete();
      }

      await targetFile.create(recursive: true);
      await targetFile.writeAsBytes(denoEntry.content as List<int>);
      await _makeExecutable(targetFile);

      return targetFile;
    } catch (error, stackTrace) {
      await AppLogger.reportError(
        error,
        stackTrace,
        "Failed to download managed Deno binary",
      );
      rethrow;
    } finally {
      if (await archiveFile.exists()) {
        await archiveFile.delete();
      }
    }
  }

  static Future<bool> ensureAvailable({
    bool downloadIfMissing = true,
    ProgressCallback? onReceiveProgress,
  }) async {
    if (!isAvailableForPlatform) return false;

    if (_ensureCompleter != null) {
      return _ensureCompleter!.future;
    }

    final completer = Completer<bool>();
    _ensureCompleter = completer;

    () async {
      try {
        if (await isInstalled()) {
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
