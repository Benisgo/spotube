import 'dart:io';

import 'package:hetu_script/hetu_script.dart';
import 'package:path/path.dart' as p;

/// A minimal file-system resource context that resolves relative `.ht`
/// imports from disk. Core `hetu_script` ships HTOverlayContext (in-memory
/// only); this lets `Hetu.compileFile()` resolve `./segments/foo.ht`
/// relative imports like the plugin's Makefile does via the `hetu` CLI.
class _HTFileSystemSourceContext extends HTResourceContext<HTSource> {
  @override
  late final String root;

  @override
  final Set<String> included = <String>{};

  final Map<String, HTSource> _cache = <String, HTSource>{};

  _HTFileSystemSourceContext({String? root}) {
    root = p.absolute(root ?? p.current);
    this.root = getAbsolutePath(dirName: root);
  }

  /// The base implementation uses Uri.file(...).path which adds a leading
  /// '/' to Windows drive paths (/C:/Users/...), breaking File().existsSync().
  /// Normalize to native paths and strip the leading slash instead.
  @override
  String getAbsolutePath({String key = '', String? dirName, String? fileName}) {
    var name = key;
    if (!p.isAbsolute(name)) {
      if (dirName != null) name = p.join(dirName, name);
      if (!p.isAbsolute(name)) name = p.join(p.current, name);
    }
    if (fileName != null) name = p.join(name, fileName);
    var normalized = p.normalize(name);
    if (RegExp(r'^/[A-Za-z]:').hasMatch(normalized)) {
      normalized = normalized.substring(1);
    }
    return normalized;
  }

  @override
  bool contains(String key) =>
      _cache.containsKey(key) || File(key).existsSync();

  @override
  void addResource(String fullName, HTSource resource) {
    _cache[fullName] = resource;
    included.add(resource.fullName);
  }

  @override
  void removeResource(String fullName) {
    _cache.remove(fullName);
    included.remove(fullName);
  }

  @override
  void updateResource(String fullName, HTSource resource) {
    _cache[fullName] = resource;
  }

  @override
  HTSource getResource(String key, {String? from}) {
    final cached = _cache[key];
    if (cached != null) return cached;

    final resolved = p.isAbsolute(key) ? key : p.normalize(p.join(root, key));
    final file = File(resolved);
    if (!file.existsSync()) {
      throw HTError.resourceDoesNotExist(key);
    }
    final source = HTSource(
      file.readAsStringSync(),
      fullName: p.normalize(resolved),
    );
    _cache[key] = source;
    included.add(source.fullName);
    return source;
  }
}

/// Compiles the Spotify plugin's plugin.ht -> plugin.out bytecode.
///
/// Usage: dart run cli/compile_spotify_plugin.dart
///
/// The app loads plugins from compiled bytecode (plugin.out), NOT the .ht
/// source. After editing any .ht source in the plugin repo, run this script
/// to regenerate the bytecode, then rebuild the .smplug archive.
void main() {
  const pluginSrc =
      'C:/Users/Ahmed Mohamed/Documents/GitHub/spotube-plugin-spotify/src/plugin.ht';
  const pluginOut =
      'C:/Users/Ahmed Mohamed/Documents/GitHub/spotube-plugin-spotify/build/plugin.out';

  if (!File(pluginSrc).existsSync()) {
    stderr.writeln('ERROR: Source file not found: $pluginSrc');
    exit(1);
  }

  stdout.writeln('Initializing Hetu with file-system source context...');
  final sourceContext =
      _HTFileSystemSourceContext(root: p.dirname(p.absolute(pluginSrc)));
  final hetu = Hetu(sourceContext: sourceContext);
  hetu.init(useDefaultModuleAndBinding: true);

  stdout.writeln('Compiling ${p.basename(pluginSrc)} -> bytecode...');
  final bytecode = hetu.compileFile(p.absolute(pluginSrc));
  stdout.writeln('  Compiled ${bytecode.length} bytes');

  stdout.writeln('Writing plugin.out...');
  File(pluginOut).writeAsBytesSync(bytecode);

  stdout.writeln('Done! Compiled ${bytecode.length} bytes -> $pluginOut');
}
