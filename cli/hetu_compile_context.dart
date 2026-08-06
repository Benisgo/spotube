import 'dart:io';

import 'package:hetu_script/hetu_script.dart';
import 'package:path/path.dart' as p;

/// A file-system Hetu source context that resolves relative `.ht` imports
/// from disk (core `hetu_script` only ships an in-memory HTOverlayContext)
/// AND makes every embedded source identifier REPO-RELATIVE, so compiled
/// bytecode never leaks the build machine's absolute path (developer username
/// / drive) into runtime error messages on end users' PCs.
class HTRepoRelativeSourceContext extends HTResourceContext<HTSource> {
  @override
  late final String root;

  @override
  final Set<String> included = <String>{};

  final Map<String, HTSource> _cache = <String, HTSource>{};

  HTRepoRelativeSourceContext({String? root}) {
    root = p.absolute(root ?? p.current);
    this.root = root;
  }

  /// Resolve a source path to a stable, REPO-RELATIVE identifier (POSIX
  /// separators). The bundler uses this for import resolution AND embeds the
  /// result in the compiled bytecode's module records, so returning relative
  /// paths here is what keeps the build machine's absolute path out of
  /// runtime error messages. Relative results are re-joined against [root]
  /// by [getResource] for the actual disk read.
  @override
  String getAbsolutePath({String key = '', String? dirName, String? fileName}) {
    var name = key;
    if (dirName != null) name = p.join(dirName, name);
    if (fileName != null) name = p.join(name, fileName);
    return _displayName(p.normalize(name));
  }

  /// Source identifiers embedded in the compiled bytecode are made
  /// repo-relative so runtime error messages never leak the build machine's
  /// absolute path (developer username / drive) onto end users' PCs.
  String _displayName(String path) {
    final rel =
        p.isAbsolute(path) ? p.relative(path, from: root) : p.normalize(path);
    return rel.replaceAll('\\', '/');
  }

  @override
  bool contains(String key) {
    if (_cache.containsKey(key)) return true;
    final resolved = p.isAbsolute(key) ? key : p.normalize(p.join(root, key));
    return File(resolved).existsSync();
  }

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
      fullName: _displayName(p.normalize(resolved)),
    );
    _cache[key] = source;
    included.add(source.fullName);
    return source;
  }
}

/// Compile a `.ht` entry into bytecode with repo-relative embedded source
/// names, writing the result to [output].
///
/// [root] is the repo/submodule root used to relativize source identifiers.
void compileHetuEntry({
  required String entry,
  required String output,
  required String root,
}) {
  final entryFile = File(entry);
  if (!entryFile.existsSync()) {
    stderr.writeln('ERROR: Source file not found: $entry');
    exit(1);
  }

  stdout.writeln('Initializing Hetu with repo-relative source context...');
  final hetu = Hetu(sourceContext: HTRepoRelativeSourceContext(root: root));
  hetu.init(useDefaultModuleAndBinding: true);

  stdout.writeln('Compiling ${p.basename(entry)} -> bytecode...');
  final bytecode = hetu.compileFile(p.absolute(entry));
  stdout.writeln('  Compiled ${bytecode.length} bytes');

  stdout.writeln('Writing $output...');
  File(output).parent.createSync(recursive: true);
  File(output).writeAsBytesSync(bytecode);

  stdout.writeln('Done! Compiled ${bytecode.length} bytes -> $output');
}
