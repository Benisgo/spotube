import 'dart:io';

import 'package:path/path.dart' as p;

import 'hetu_compile_context.dart';

/// Compiles the Spotify GraphQL client (hetu_spotify_gql_client) bytecode:
/// spotify_gql_api_client.ht -> spotify_gql_api_client.out, and copies it
/// into the app's bundled asset (assets/bytecode/spotify_gql_api_client.out).
///
/// Why this exists: the gql client is a git submodule of the Spotify plugin
/// repo (dependencies/hetu_spotify_gql_client). The app loads it SEPARATELY
/// from the plugin (see lib/services/metadata/metadata.dart), and the
/// submodule's own Makefile compiles with the plain `hetu` CLI — which embeds
/// ABSOLUTE source paths. So runtime errors in its scripts (e.g. artist.ht)
/// leak the build machine's username/drive onto end users' PCs, and source
/// fixes there are not picked up by the app until this bytecode is rebuilt.
/// This script compiles it with repo-relative source names (same as the
/// plugin compile) and drops it into the app's bundled assets.
void main() {
  final scriptDir = p.dirname(Platform.script.toFilePath());
  final parentDir = p.dirname(p.dirname(scriptDir));
  final pluginRepo = Platform.environment['SPOTUBE_PLUGIN_REPO'] ??
      p.join(parentDir, 'spotube-plugin-spotify');
  final submodule =
      p.join(pluginRepo, 'dependencies', 'hetu_spotify_gql_client');

  final entry =
      p.join(submodule, 'lib', 'assets', 'hetu', 'spotify_gql_api_client.ht');
  final output = p.join(
      submodule, 'lib', 'assets', 'bytecode', 'spotify_gql_api_client.out');

  compileHetuEntry(
    entry: entry,
    output: output,
    root: submodule,
  );

  // Copy into the app's bundled assets so the running app picks it up.
  final appAsset = p.normalize(p.join(
      scriptDir, '..', 'assets', 'bytecode', 'spotify_gql_api_client.out'));
  final dest = File(appAsset);
  dest.parent.createSync(recursive: true);
  File(output).copySync(dest.path);
  stdout.writeln('Copied -> ${dest.path}');
}
