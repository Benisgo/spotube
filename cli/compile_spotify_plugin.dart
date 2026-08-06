import 'dart:io';

import 'package:path/path.dart' as p;

import 'hetu_compile_context.dart';

/// Compiles the Spotify plugin's plugin.ht -> plugin.out bytecode.
///
/// Usage: dart run cli/compile_spotify_plugin.dart
///
/// The app loads plugins from compiled bytecode (plugin.out), NOT the .ht
/// source. After editing any .ht source in the plugin repo, run this script
/// to regenerate the bytecode, then rebuild the .smplug archive.
void main() {
  // Resolve the plugin repo RELATIVE to this script so the repo never
  // hardcodes the developer's machine path (which would leak the username /
  // drive on GitHub). Expected layout:
  //   <parent>/spotube/cli/compile_spotify_plugin.dart
  //   <parent>/spotube-plugin-spotify/        (sibling plugin repo)
  final scriptDir = p.dirname(Platform.script.toFilePath());
  final parentDir = p.dirname(p.dirname(scriptDir));
  final pluginRepo = Platform.environment['SPOTUBE_PLUGIN_REPO'] ??
      p.join(parentDir, 'spotube-plugin-spotify');

  final pluginSrc = p.join(pluginRepo, 'src', 'plugin.ht');
  final pluginOut = p.join(pluginRepo, 'build', 'plugin.out');

  if (!File(pluginSrc).existsSync()) {
    stderr.writeln(
      'ERROR: Source file not found: $pluginSrc\n'
      'Expected the Spotify plugin repo (spotube-plugin-spotify) as a '
      'sibling of this spotube checkout, or set the SPOTUBE_PLUGIN_REPO env '
      'var to its path.',
    );
    exit(1);
  }

  compileHetuEntry(
    entry: pluginSrc,
    output: pluginOut,
    root: pluginRepo,
  );
}
