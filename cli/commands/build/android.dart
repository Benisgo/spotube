import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart';

import '../../core/env.dart';
import 'common.dart';

class AndroidBuildCommand extends Command with BuildCommandCommonSteps {
  @override
  String get description => "Build for android";

  @override
  String get name => "android";

  @override
  FutureOr? run() async {
    await bootstrap();

    await shell.run(
      "flutter build apk --flavor ${CliEnv.channel.name}",
    );

    final ogApkFile = File(
      join(
        "build",
        "app",
        "outputs",
        "flutter-apk",
        "app-${CliEnv.channel.name}-release.apk",
      ),
    );

    await ogApkFile.copy(
      join(cwd.path, "build", "Spotube-android-all-arch.apk"),
    );

    // Also build per-ABI APKs so users can download a much smaller
    // (~30-40 MB) APK for their device instead of the ~110 MB universal one.
    // --target-platform limits the build to ARM ABIs (the Flutter Gradle plugin
    // overrides any gradle ndk.abiFilters with its own DEFAULT_PLATFORMS list,
    // so this flag is the ONLY reliable way to control what ships).
    // This is best-effort: a failure here must NOT fail the release — the
    // universal APK above is always produced and uploaded.
    const abis = ["arm64-v8a", "armeabi-v7a"];
    try {
      await shell.run(
        "flutter build apk --split-per-abi "
        "--target-platform android-arm64,android-arm "
        "--flavor ${CliEnv.channel.name}",
      );
      for (final abi in abis) {
        final abiApk = File(
          join(
            "build",
            "app",
            "outputs",
            "flutter-apk",
            "app-${CliEnv.channel.name}-$abi-release.apk",
          ),
        );
        if (abiApk.existsSync()) {
          await abiApk.copy(
            join(cwd.path, "build", "Spotube-android-$abi.apk"),
          );
        }
      }
    } catch (error) {
      stdout.writeln(
        "⚠️ Per-ABI APK build skipped (release continues with the "
        "universal APK): $error",
      );
    }

    stdout.writeln("✅ Built Android Apk (universal + per-ABI)");
  }
}
