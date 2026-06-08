import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/utils/platform.dart';

class _PythonLaunchSpec {
  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;

  const _PythonLaunchSpec({
    required this.executable,
    required this.arguments,
    required this.environment,
  });
}

class _YtDlpWorkerProcessException implements Exception {
  final String message;

  const _YtDlpWorkerProcessException(this.message);

  @override
  String toString() => message;
}

class _YtDlpWorkerUnavailableException implements Exception {
  final String message;

  const _YtDlpWorkerUnavailableException(this.message);

  @override
  String toString() => message;
}

class _YtDlpWorkerRemoteException implements Exception {
  final String message;
  final String? type;

  const _YtDlpWorkerRemoteException(this.message, {this.type});

  @override
  String toString() => type == null ? message : '$type: $message';
}

class _YtDlpWorkerResponse {
  final bool ok;
  final dynamic result;
  final String? error;
  final String? errorType;

  const _YtDlpWorkerResponse({
    required this.ok,
    this.result,
    this.error,
    this.errorType,
  });
}

enum YtDlpRequestPriority { foreground, background }

enum _YtDlpWorkerRole { foreground, background }

class _YtDlpExecutionContextValue {
  final YtDlpRequestPriority priority;
  final String? cancelGroup;
  final bool discardIfStale;

  const _YtDlpExecutionContextValue({
    required this.priority,
    this.cancelGroup,
    this.discardIfStale = false,
  });
}

class YtDlpExecutionContext {
  static final Object _zoneKey = Object();

  static _YtDlpExecutionContextValue get _current =>
      Zone.current[_zoneKey] as _YtDlpExecutionContextValue? ??
      const _YtDlpExecutionContextValue(
        priority: YtDlpRequestPriority.foreground,
      );

  static bool get isBackground =>
      _current.priority == YtDlpRequestPriority.background;

  static YtDlpRequestPriority get currentPriority => _current.priority;

  static Future<T> runForeground<T>(
    Future<T> Function() action, {
    String? cancelGroup,
  }) {
    return runZoned(
      action,
      zoneValues: {
        _zoneKey: _YtDlpExecutionContextValue(
          priority: YtDlpRequestPriority.foreground,
          cancelGroup: cancelGroup,
        ),
      },
    );
  }

  static Future<T> runBackground<T>(
    Future<T> Function() action, {
    String? cancelGroup,
    bool discardIfStale = true,
  }) {
    return runZoned(
      action,
      zoneValues: {
        _zoneKey: _YtDlpExecutionContextValue(
          priority: YtDlpRequestPriority.background,
          cancelGroup: cancelGroup,
          discardIfStale: discardIfStale,
        ),
      },
    );
  }
}

class YtDlpWorkerRuntime {
  static const _workerVersion = 'v1';
  static const _workerAssetPath = 'assets/yt_dlp_worker/worker.py';
  static const _managedPackage = 'yt-dlp';

  static Future<Directory> get _workerDirectory async {
    final supportDirectory = await getApplicationSupportDirectory();
    final directory = Directory(
      join(supportDirectory.path, 'bin', 'yt_dlp_worker', _workerVersion),
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  static Future<File> get _workerScriptFile async {
    final directory = await _workerDirectory;
    return File(join(directory.path, 'worker.py'));
  }

  static Future<Directory> get _sitePackagesDirectory async {
    final directory = await _workerDirectory;
    final sitePackages = Directory(join(directory.path, 'site-packages'));
    if (!await sitePackages.exists()) {
      await sitePackages.create(recursive: true);
    }
    return sitePackages;
  }

  static Future<void> ensureWorkerScript() async {
    if (!kIsDesktop) return;

    final file = await _workerScriptFile;
    final asset = await rootBundle.loadString(_workerAssetPath);
    if (await file.exists()) {
      final current = await file.readAsString();
      if (current == asset) return;
    }
    await file.writeAsString(asset);
  }

  static Future<List<_PythonLaunchSpec>> _candidateLaunchSpecs() async {
    final scriptFile = await _workerScriptFile;
    final sitePackages = await _sitePackagesDirectory;
    final currentPythonPath = Platform.environment['PYTHONPATH'];
    final pythonPath = [
      sitePackages.path,
      if (currentPythonPath != null && currentPythonPath.isNotEmpty)
        currentPythonPath,
    ].join(Platform.isWindows ? ';' : ':');

    final environment = {
      'PYTHONPATH': pythonPath,
      'PYTHONUNBUFFERED': '1',
    };

    final bundledRuntimeCandidates = [
      join((await _workerDirectory).path, 'python', 'python.exe'),
      join((await _workerDirectory).path, 'python', 'bin', 'python3'),
      join((await _workerDirectory).path, 'python', 'bin', 'python'),
    ];

    final specs = <_PythonLaunchSpec>[];
    for (final candidate in bundledRuntimeCandidates) {
      if (await File(candidate).exists()) {
        specs.add(
          _PythonLaunchSpec(
            executable: candidate,
            arguments: ['-u', scriptFile.path],
            environment: environment,
          ),
        );
      }
    }

    if (Platform.isWindows) {
      specs.add(
        _PythonLaunchSpec(
          executable: 'py',
          arguments: ['-3', '-u', scriptFile.path],
          environment: environment,
        ),
      );
    }

    specs.add(
      _PythonLaunchSpec(
        executable: 'python',
        arguments: ['-u', scriptFile.path],
        environment: environment,
      ),
    );
    specs.add(
      _PythonLaunchSpec(
        executable: 'python3',
        arguments: ['-u', scriptFile.path],
        environment: environment,
      ),
    );

    return specs;
  }

  static Future<bool> _canRun(
    _PythonLaunchSpec spec, {
    List<String> extraArgs = const [],
  }) async {
    try {
      final result = await Process.run(
        spec.executable,
        [...spec.arguments.take(spec.arguments.length - 1), ...extraArgs],
        environment: spec.environment,
        runInShell: Platform.isWindows,
      );
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<_PythonLaunchSpec?> _findAvailablePython() async {
    final specs = await _candidateLaunchSpecs();
    for (final spec in specs) {
      if (await _canRun(spec, extraArgs: ['-c', 'import sys'])) {
        return spec;
      }
    }
    return null;
  }

  static Future<bool> _hasYtDlpModule(_PythonLaunchSpec spec) async {
    return _canRun(
      spec,
      extraArgs: ['-c', 'import yt_dlp'],
    );
  }

  static Future<bool> _installYtDlpModule(_PythonLaunchSpec spec) async {
    try {
      final sitePackages = await _sitePackagesDirectory;
      final result = await Process.run(
        spec.executable,
        [
          ...spec.arguments.take(spec.arguments.length - 1),
          '-m',
          'pip',
          'install',
          '--disable-pip-version-check',
          '--no-warn-script-location',
          '--upgrade',
          '--target',
          sitePackages.path,
          _managedPackage,
        ],
        environment: spec.environment,
        runInShell: Platform.isWindows,
      );
      if (result.exitCode != 0) {
        AppLogger.agentDebug(
          'yt_dlp_worker.dart:pip_install',
          'yt_dlp.worker.install_failed',
          {
            'exitCode': result.exitCode,
            'stderr': result.stderr.toString(),
          },
          hypothesisId: 'PLAYBACK_START',
          runId: 'startup-trace',
        );
      }
      return result.exitCode == 0;
    } catch (error, stackTrace) {
      await AppLogger.reportError(
        error,
        stackTrace,
        'Failed to install yt-dlp python module for worker',
      );
      return false;
    }
  }

  static Future<_PythonLaunchSpec?> _prepare({bool allowInstall = true}) async {
    if (!kIsDesktop) return null;

    await ensureWorkerScript();
    final python = await _findAvailablePython();
    if (python == null) return null;

    if (await _hasYtDlpModule(python)) {
      return python;
    }

    if (!allowInstall) {
      return null;
    }

    final installed = await _installYtDlpModule(python);
    if (!installed || !await _hasYtDlpModule(python)) {
      return null;
    }

    return python;
  }
}

class YtDlpWorkerClient {
  static const requestTimeout = Duration(seconds: 25);
  static const startupTimeout = Duration(seconds: 3);
  static const firstRequestStartupBudget = Duration(milliseconds: 1200);
  static const _backgroundCooldown = Duration(seconds: 8);

  static final YtDlpWorkerClient foreground = YtDlpWorkerClient._(
    _YtDlpWorkerRole.foreground,
  );
  static final YtDlpWorkerClient background = YtDlpWorkerClient._(
    _YtDlpWorkerRole.background,
  );
  static DateTime? _backgroundDeferredUntil;

  static YtDlpWorkerClient get instance => foreground;

  final _YtDlpWorkerRole _role;

  YtDlpWorkerClient._(this._role);

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  Future<bool>? _startupFuture;
  Future<void> _stdinWriteQueue = Future.value();
  final Map<String, Completer<_YtDlpWorkerResponse>> _pendingRequests = {};
  int _requestId = 0;

  bool get isHealthy => _process != null;

  String get _roleLabel => _role.name;

  static void notifyForegroundPlaybackStart() {
    _backgroundDeferredUntil = DateTime.now().add(_backgroundCooldown);
    unawaited(background.cancelPendingWork('foreground_playback_started'));
  }

  static bool get shouldDeferBackgroundWork {
    final until = _backgroundDeferredUntil;
    return until != null && until.isAfter(DateTime.now());
  }

  Future<void> prewarm() async {
    if (!kIsDesktop) return;
    await _ensureStarted(
      timeout: startupTimeout,
      allowInstall: true,
      failSilently: true,
    );
  }

  Future<bool> _ensureStarted({
    required Duration timeout,
    required bool allowInstall,
    bool failSilently = false,
  }) async {
    if (_process != null) return true;

    final active = _startupFuture;
    if (active != null) {
      try {
        return await active.timeout(timeout);
      } catch (_) {
        return false;
      }
    }

    final future = _startInternal(allowInstall: allowInstall);
    _startupFuture = future;
    try {
      return await future.timeout(timeout);
    } catch (error, stackTrace) {
      if (!failSilently) {
        await AppLogger.reportError(
          error,
          stackTrace,
          'Failed to start yt-dlp worker',
        );
      }
      await _killProcess();
      return false;
    } finally {
      if (identical(_startupFuture, future)) {
        _startupFuture = null;
      }
    }
  }

  Future<bool> _startInternal({required bool allowInstall}) async {
    final spec = await YtDlpWorkerRuntime._prepare(allowInstall: allowInstall);
    if (spec == null) {
      return false;
    }

    final process = await Process.start(
      spec.executable,
      spec.arguments,
      environment: spec.environment,
      runInShell: Platform.isWindows,
    );

    _process = process;
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleStdoutLine, onDone: _handleProcessClosed);
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleStderrLine, onDone: () {});

    final healthy = await _sendRequestInternal(
      'ping',
      const {},
      timeout: startupTimeout,
    ).then((response) => response.ok).catchError((_) => false);

    if (!healthy) {
      await _killProcess();
      return false;
    }

    AppLogger.agentDebug(
      'yt_dlp_worker.dart:start',
      'yt_dlp.worker.ready',
      {'backend': 'worker', 'worker': _roleLabel},
      hypothesisId: 'PLAYBACK_START',
      runId: 'startup-trace',
    );
    return true;
  }

  void _handleStdoutLine(String line) {
    try {
      final payload = jsonDecode(line) as Map<String, dynamic>;
      final id = payload['id']?.toString();
      if (id == null) {
        throw const _YtDlpWorkerProcessException(
          'Worker protocol missing response id',
        );
      }

      final completer = _pendingRequests.remove(id);
      if (completer == null || completer.isCompleted) return;

      completer.complete(
        _YtDlpWorkerResponse(
          ok: payload['ok'] == true,
          result: payload['result'],
          error: payload['error']?.toString(),
          errorType: payload['errorType']?.toString(),
        ),
      );
    } catch (error) {
      AppLogger.agentDebug(
        'yt_dlp_worker.dart:stdout',
        'yt_dlp.worker.malformed_stdout',
        {
          'line': line,
          'error': error.toString(),
          'worker': _roleLabel,
        },
        hypothesisId: 'PLAYBACK_START',
        runId: 'startup-trace',
      );
      _failAllPending(
        const _YtDlpWorkerProcessException('Malformed worker stdout protocol'),
      );
      unawaited(_killProcess());
    }
  }

  void _handleStderrLine(String line) {
    if (!kDebugMode || line.trim().isEmpty) return;
    AppLogger.agentDebug(
      'yt_dlp_worker.dart:stderr',
      'yt_dlp.worker.stderr',
      {'line': line, 'worker': _roleLabel},
      hypothesisId: 'PLAYBACK_START',
      runId: 'startup-trace',
    );
  }

  void _handleProcessClosed() {
    _failAllPending(
      const _YtDlpWorkerUnavailableException('yt-dlp worker exited'),
    );
    _disposeProcessState();
  }

  Future<void> _killProcess() async {
    final process = _process;
    _disposeProcessState();
    if (process == null) return;
    process.kill(ProcessSignal.sigkill);
  }

  Future<void> cancelPendingWork(String reason) async {
    _failAllPending(
      _YtDlpWorkerUnavailableException(
        'yt-dlp $_roleLabel worker cancelled: $reason',
      ),
    );
    await _killProcess();
    AppLogger.agentDebug(
      'yt_dlp_worker.dart:cancel',
      'yt_dlp.worker.cancelled',
      {
        'worker': _roleLabel,
        'reason': reason,
      },
      hypothesisId: 'PLAYBACK_START',
      runId: 'startup-trace',
    );
  }

  void _disposeProcessState() {
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _process = null;
  }

  void _failAllPending(Object error) {
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pendingRequests.clear();
  }

  Future<_YtDlpWorkerResponse> _sendRequestInternal(
    String method,
    Map<String, Object?> params, {
    required Duration timeout,
  }) async {
    final process = _process;
    if (process == null) {
      throw const _YtDlpWorkerUnavailableException('yt-dlp worker not running');
    }

    final id = (++_requestId).toString();
    final completer = Completer<_YtDlpWorkerResponse>();
    _pendingRequests[id] = completer;

    Timer(timeout, () {
      final pending = _pendingRequests.remove(id);
      if (pending != null && !pending.isCompleted) {
        pending.completeError(
          _YtDlpWorkerUnavailableException(
            'yt-dlp worker request timed out for $method',
          ),
        );
      }
    });

    final payload = jsonEncode({
      'id': id,
      'method': method,
      'params': params,
    });
    try {
      final writeFuture = _stdinWriteQueue.then((_) async {
        process.stdin.writeln(payload);
        await process.stdin.flush();
      });
      _stdinWriteQueue = writeFuture.catchError((_) {});
      await writeFuture;
    } catch (error) {
      _pendingRequests.remove(id);
      if (!completer.isCompleted) {
        completer.completeError(
          _YtDlpWorkerUnavailableException(
            'yt-dlp worker write failed for $method: $error',
          ),
        );
      }
      rethrow;
    }

    return completer.future;
  }

  Future<dynamic> _execute(
    String method,
    Map<String, Object?> params, {
    bool allowInstall = true,
    bool restartOnFailure = true,
  }) async {
    if (_role == _YtDlpWorkerRole.background && shouldDeferBackgroundWork) {
      throw const _YtDlpWorkerUnavailableException(
        'yt-dlp background worker deferred for active foreground playback',
      );
    }

    final started = await _ensureStarted(
      timeout: firstRequestStartupBudget,
      allowInstall: allowInstall,
      failSilently: true,
    );
    if (!started) {
      throw const _YtDlpWorkerUnavailableException(
        'yt-dlp worker unavailable',
      );
    }

    try {
      final response = await _sendRequestInternal(
        method,
        params,
        timeout: requestTimeout,
      );
      if (!response.ok) {
        throw _YtDlpWorkerRemoteException(
          response.error ?? 'yt-dlp worker request failed',
          type: response.errorType,
        );
      }
      return response.result;
    } on _YtDlpWorkerUnavailableException {
      if (!restartOnFailure) rethrow;
      await _killProcess();
      final restarted = await _ensureStarted(
        timeout: startupTimeout,
        allowInstall: false,
        failSilently: true,
      );
      if (!restarted) rethrow;

      final response = await _sendRequestInternal(
        method,
        params,
        timeout: requestTimeout,
      );
      if (!response.ok) {
        throw _YtDlpWorkerRemoteException(
          response.error ?? 'yt-dlp worker request failed',
          type: response.errorType,
        );
      }
      return response.result;
    }
  }

  Future<List<dynamic>> getStreamManifest(String videoId) async {
    final result = await _execute(
      'get_stream_manifest',
      {'videoId': videoId},
      restartOnFailure: _role == _YtDlpWorkerRole.foreground,
    );
    return (result as List).cast<dynamic>();
  }

  Future<Map<String, dynamic>> getVideo(String videoId) async {
    final result = await _execute(
      'get_video',
      {'videoId': videoId},
      restartOnFailure: _role == _YtDlpWorkerRole.foreground,
    );
    return (result as Map).cast<String, dynamic>();
  }

  Future<(Map<String, dynamic>, List<dynamic>)> getVideoWithStreamInfo(
    String videoId,
  ) async {
    final result = await _execute(
      'get_video_with_stream_info',
      {'videoId': videoId},
      restartOnFailure: _role == _YtDlpWorkerRole.foreground,
    );
    final map = (result as Map).cast<String, dynamic>();
    return (
      (map['video'] as Map).cast<String, dynamic>(),
      (map['formats'] as List).cast<dynamic>(),
    );
  }

  Future<List<Map<String, dynamic>>> searchVideos(String query, int count) async {
    final result = await _execute(
      'search_videos',
      {
        'query': query,
        'count': count,
      },
      restartOnFailure: _role == _YtDlpWorkerRole.foreground,
    );
    return (result as List)
        .map((item) => (item as Map).cast<String, dynamic>())
        .toList();
  }
}
