import 'dart:io';
import 'package:hetu_script/hetu_script.dart';

/// Compiles plugin.ht -> plugin.out bytecode.
///
/// Usage: dart run cli/compile_youtube_plugin.dart
///
/// External class declarations (Webview, LocalStorage, YouTubeEngine)
/// are inlined in plugin.ht, so no pre-loaded bytecode is needed.
void main() {
  const pluginSrc = 'assets/plugins/spotube-plugin-youtube-audio/plugin.ht';
  const pluginOut = 'assets/plugins/spotube-plugin-youtube-audio/plugin.out';

  if (!File(pluginSrc).existsSync()) {
    stderr.writeln('ERROR: Source file not found: $pluginSrc');
    exit(1);
  }

  stdout.writeln('Initializing Hetu...');
  final hetu = Hetu();
  hetu.init(useDefaultModuleAndBinding: true);

  stdout.writeln('Reading source...');
  final source = File(pluginSrc).readAsStringSync();
  stdout.writeln('  Read ${source.length} chars');

  stdout.writeln('Compiling to bytecode...');
  final bytecode = hetu.compile(source, sourceName: 'plugin.ht');
  stdout.writeln('  Compiled ${bytecode.length} bytes');

  stdout.writeln('Writing plugin.out...');
  File(pluginOut).writeAsBytesSync(bytecode);

  stdout.writeln('Done! Compiled ${bytecode.length} bytes -> $pluginOut');
}
