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
    // --target-platform is the ONLY reliable way to control what ships (the
    // Flutter Gradle plugin overrides any gradle ndk.abiFilters with its own
    // DEFAULT_PLATFORMS list).
    //
    // Each ABI is built in its own invocation so a failure on one ABI (e.g.
    // x86_64) can't silently drop the others — the per-ABI APKs are what the
    // release uploads, so this keeps every architecture available even when a
    // single target misbehaves on the runner.
    const abis = [
      (abi: "arm64-v8a", target: "android-arm64"),
      (abi: "armeabi-v7a", target: "android-arm"),
      (abi: "x86_64", target: "android-x64"),
    ];
    for (final entry in abis) {
      try {
        await shell.run(
          "flutter build apk --split-per-abi "
          "--target-platform ${entry.target} "
          "--flavor ${CliEnv.channel.name}",
        );
        final abiApk = File(
          join(
            "build",
            "app",
            "outputs",
            "flutter-apk",
            "app-${CliEnv.channel.name}-${entry.abi}-release.apk",
          ),
        );
        if (abiApk.existsSync()) {
          await abiApk.copy(
            join(cwd.path, "build", "Spotube-android-${entry.abi}.apk"),
          );
          stdout.writeln(
            "✅ Built per-ABI APK: Spotube-android-${entry.abi}.apk",
          );
        } else {
          stdout.writeln(
            "⚠️ Per-ABI APK not found after build: ${entry.abi}",
          );
        }
      } catch (error) {
        stdout.writeln(
          "⚠️ Per-ABI APK build skipped for ${entry.abi} "
          "(release continues with the universal APK): $error",
        );
      }
    }

    stdout.writeln("✅ Built Android Apk (universal + per-ABI)");
  }
}
