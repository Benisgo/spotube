import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart';
import 'package:process_run/shell_run.dart';
import 'package:pubspec_parse/pubspec_parse.dart';

import '../../core/env.dart';

mixin BuildCommandCommonSteps on Command {
  final shell = Shell();
  Directory get cwd => Directory.current;

  Pubspec? _pubspec;

  Pubspec get pubspec {
    if (_pubspec != null) {
      return _pubspec!;
    }

    final pubspecFile = File(join(cwd.path, "pubspec.yaml"));
    _pubspec = Pubspec.parse(pubspecFile.readAsStringSync());

    return _pubspec!;
  }

  String get versionWithoutBuildNumber {
    return "${pubspec.version!.major}.${pubspec.version!.minor}.${pubspec.version!.patch}";
  }

  RegExp get versionVarRegExp =>
      RegExp(r"\%\{\{SPOTUBE_VERSION\}\}\%", multiLine: true);

  File get dotEnvFile => File(join(cwd.path, ".env"));

  Future<void> bootstrap() async {
    await dotEnvFile.create(recursive: true);

    final repository = CliEnv.githubRepository ?? "Benisgo/spotube";
    final serverUrl = CliEnv.githubServerUrl ?? "https://github.com";
    final releasesUrl = "$serverUrl/$repository/releases/latest";
    final nightlyUrl = "$serverUrl/$repository/releases/tag/nightly";

    final dotenvPayload = CliEnv.dotenv.trim().isEmpty
        ? [
            "ENABLE_UPDATE_CHECK=1",
            "LASTFM_API_KEY=",
            "LASTFM_API_SECRET=",
            "HIDE_DONATIONS=0",
            "APP_UPDATE_REPOSITORY=$repository",
            "APP_DOWNLOAD_URL=$releasesUrl",
            "APP_NIGHTLY_DOWNLOAD_URL=$nightlyUrl",
          ].join("\n")
        : CliEnv.dotenv.trim();

    await dotEnvFile.writeAsString(
      "$dotenvPayload\n"
      "RELEASE_CHANNEL=${CliEnv.channel.name}\n",
    );

    if (CliEnv.channel == BuildChannel.nightly) {
      final pubspecFile = File(join(cwd.path, "pubspec.yaml"));

      pubspecFile.writeAsStringSync(
        pubspecFile.readAsStringSync().replaceAll(
              "version: ${pubspec.version!.canonicalizedVersion}",
              "version: $versionWithoutBuildNumber+${CliEnv.ghRunNumber}",
            ),
      );

      _pubspec = null;
      pubspec;
    }

    await shell.run(
      """
      flutter pub get
      dart run build_runner build --delete-conflicting-outputs
      dart pub global activate fastforge
      """,
    );
  }

  String get architecture => parent?.argResults?.option("arch") as String;
}
