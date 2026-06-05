import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:spotube/services/kv_store/kv_store.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/utils/platform.dart';
import 'package:window_manager/window_manager.dart';

class WindowSize {
  final double height;
  final double width;
  final bool maximized;

  WindowSize({
    required this.height,
    required this.width,
    required this.maximized,
  });

  factory WindowSize.fromJson(Map<String, dynamic> json) => WindowSize(
        height: json["height"],
        width: json["width"],
        maximized: json["maximized"],
      );

  Map<String, dynamic> toJson() => {
        "height": height,
        "width": width,
        "maximized": maximized,
      };
}

class WindowManagerTools with WidgetsBindingObserver {
  static const _minimumWidth = 300.0;
  static const _minimumHeight = 700.0;

  static WindowManagerTools? _instance;
  static WindowManagerTools get instance => _instance!;

  WindowManagerTools._();

  static Future<void> initialize() async {
    await windowManager.ensureInitialized();
    _instance = WindowManagerTools._();
    WidgetsBinding.instance.addObserver(instance);

    // In debug, the Dart debugger can pause on handled startup exceptions
    // before the first Flutter frame is rendered. Showing the window early
    // avoids the "running process but no visible window" state.
    if (kDebugMode && kIsWindows) {
      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
    }

    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: "Spotube",
        backgroundColor: Colors.transparent,
        minimumSize: Size(_minimumWidth, _minimumHeight),
        titleBarStyle: TitleBarStyle.hidden,
        center: true,
      ),
      () async {
        final savedSize = KVStoreService.windowSize;
        try {
          await windowManager.setResizable(true);
          await windowManager.setSkipTaskbar(false);

          if (savedSize?.maximized == true &&
              !(await windowManager.isMaximized())) {
            await windowManager.maximize();
          } else if (savedSize != null) {
            final width = savedSize.width < _minimumWidth
                ? _minimumWidth
                : savedSize.width;
            final height = savedSize.height < _minimumHeight
                ? _minimumHeight
                : savedSize.height;

            await windowManager.setSize(Size(width, height));
          }

          await windowManager.restore();
          await windowManager.show();
          await windowManager.focus();
        } catch (error, stackTrace) {
          await AppLogger.reportError(
            error,
            stackTrace,
            "Failed to restore Spotube window state",
          );
          await windowManager.show();
          await windowManager.focus();
        }
      },
    );
  }

  Size? _prevSize;

  @override
  void didChangeMetrics() async {
    super.didChangeMetrics();
    if (kIsMobile) return;
    final size = await windowManager.getSize();
    final windowSameDimension =
        _prevSize?.width == size.width && _prevSize?.height == size.height;

    if (windowSameDimension || _prevSize == null) {
      _prevSize = size;
      return;
    }
    final isMaximized = await windowManager.isMaximized();
    await KVStoreService.setWindowSize(
      WindowSize(
        height: size.height,
        width: size.width,
        maximized: isMaximized,
      ),
    );
    _prevSize = size;
  }
}
