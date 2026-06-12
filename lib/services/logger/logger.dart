import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' hide join;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotube/utils/platform.dart';
import 'package:logging/logging.dart' as logging;

final _loggingToLoggerLevel = {
  logging.Level.ALL: Level.all,
  logging.Level.FINEST: Level.trace,
  logging.Level.FINER: Level.debug,
  logging.Level.FINE: Level.info,
  logging.Level.CONFIG: Level.info,
  logging.Level.INFO: Level.info,
  logging.Level.WARNING: Level.warning,
  logging.Level.SEVERE: Level.error,
  logging.Level.SHOUT: Level.fatal,
  logging.Level.OFF: Level.off,
};

class AppLogger {
  static late final Logger log;
  static late final File logFile;
  static late final File criticalLogFile;
  static Future<void> _traceWriteQueue = Future.value();
  static Future<void> _criticalWriteQueue = Future.value();
  static int _traceBacklog = 0;
  static bool debugTelemetryEnabled = false;

  static initialize(bool verbose) {
    debugTelemetryEnabled = verbose;
    log = Logger(
      level: verbose ? Level.all : Level.info,
      printer: kDebugMode
          ? SimplePrinter(
              printTime: true,
              colors: false,
            )
          : PrettyPrinter(),
    );
  }

  static void _initInternalPackageLoggers() {
    if (!kDebugMode) return;
    logging.hierarchicalLoggingEnabled = true;
    logging.Logger('YoutubeExplode.StreamsClient')
      ..level = logging.Level.SEVERE
      ..onRecord.listen(
        (record) {
          log.log(
            _loggingToLoggerLevel[record.level] ?? Level.info,
            record.message,
            error: record.error,
            stackTrace: record.stackTrace,
            time: record.time,
          );
        },
      );
  }

  static R? runZoned<R>(R Function() body) {
    return runZonedGuarded<R>(
      () {
        WidgetsFlutterBinding.ensureInitialized();

        FlutterError.onError = (details) {
          reportError(details.exception, details.stack ?? StackTrace.current);
        };

        PlatformDispatcher.instance.onError = (error, stackTrace) {
          reportError(error, stackTrace);
          return true;
        };

        if (!kIsWeb) {
          Isolate.current.addErrorListener(
            RawReceivePort((pair) async {
              final isolateError = pair as List<dynamic>;
              reportError(
                isolateError.first.toString(),
                isolateError.last,
              );
            }).sendPort,
          );
        }

        _initInternalPackageLoggers();

        getLogsPath().then((value) => logFile = value);
        getCriticalLogsPath().then((value) => criticalLogFile = value);

        return body();
      },
      (error, stackTrace) {
        reportError(error, stackTrace);
      },
    );
  }

  static Future<File> getLogsPath() async {
    String dir = (await getApplicationDocumentsDirectory()).path;
    if (kIsAndroid) {
      dir = (await getExternalStorageDirectory())?.path ?? "";
    }

    if (kIsMacOS) {
      dir = join((await getLibraryDirectory()).path, "Logs");
    }

    if (kIsLinux) {
      dir = join(_getXdgStateHome(), "spotube");
    }

    final file = File(join(dir, ".spotube_logs"));
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    return file;
  }

  static Future<File> getCriticalLogsPath() async {
    String dir = (await getApplicationDocumentsDirectory()).path;
    if (kIsAndroid) {
      dir = (await getExternalStorageDirectory())?.path ?? "";
    }

    if (kIsMacOS) {
      dir = join((await getLibraryDirectory()).path, "Logs");
    }

    if (kIsLinux) {
      dir = join(_getXdgStateHome(), "spotube");
    }

    final file = File(join(dir, ".spotube_critical_logs"));
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    return file;
  }

  static Future<void> reportError(
    dynamic error, [
    StackTrace? stackTrace,
    message = "",
  ]) async {
    log.e(message, error: error, stackTrace: stackTrace);

    if (kReleaseMode) {
      await logFile.writeAsString(
        "[${DateTime.now()}]---------------------\n"
        "$error\n$stackTrace\n"
        "----------------------------------------\n",
        mode: FileMode.writeOnlyAppend,
      );
    }
  }

  static void agentDebug(
    String location,
    String message,
    Map<String, dynamic> data, {
    String hypothesisId = 'A',
    String runId = 'post-fix',
  }) {
    if (!kDebugMode || !debugTelemetryEnabled) return;
    log.d('[agentDebug:$location] $message | data: $data');
  }

  static void trace(String message) {
    if (!kReleaseMode) return;
    log.i(message);
    if (_traceBacklog > 200) return;

    try {
      final file = logFile;
      _traceBacklog++;
      _traceWriteQueue = _traceWriteQueue
          .then(
            (_) => file.writeAsString(
              "[${DateTime.now()}][trace] $message\n",
              mode: FileMode.writeOnlyAppend,
            ),
          )
          .whenComplete(() {
            _traceBacklog = (_traceBacklog - 1).clamp(0, 1 << 30);
          })
          .catchError((_) => file);
    } catch (_) {}
  }

  static void criticalTrace(String message) {
    if (!kReleaseMode) return;

    log.i("[critical] $message");

    try {
      final file = criticalLogFile;
      _criticalWriteQueue = _criticalWriteQueue
          .then(
            (_) => file.writeAsString(
              "[${DateTime.now()}][critical] $message\n",
              mode: FileMode.writeOnlyAppend,
            ),
          )
          .catchError((_) => file);
    } catch (_) {}
  }

  static String _getXdgStateHome() {
    // path_provider seems does not support XDG_STATE_HOME,
    // which is the specification to store application logs on Linux.
    // See https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
    // TODO: Use path_provider once it supports XDG_STATE_HOME
    if (const bool.hasEnvironment("XDG_STATE_HOME")) {
      String xdgStateHomeRaw = Platform.environment["XDG_STATE_HOME"] ?? "";
      if (xdgStateHomeRaw.isNotEmpty) {
        return xdgStateHomeRaw;
      }
    }
    return join(Platform.environment["HOME"] ?? "", ".local", "state");
  }
}

class AppLoggerProviderObserver extends ProviderObserver {
  const AppLoggerProviderObserver();

  @override
  void providerDidFail(
    ProviderBase<Object?> provider,
    Object error,
    StackTrace stackTrace,
    ProviderContainer container,
  ) {
    AppLogger.reportError(error, stackTrace);
  }
}
