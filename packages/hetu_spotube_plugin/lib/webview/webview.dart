import 'dart:async';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart'
    as webview_window;
import 'package:flutter/widgets.dart';
import 'package:hetu_spotube_plugin/webview/webview_page.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:random_user_agents/random_user_agents.dart';
import 'package:sqlite3/sqlite3.dart';

class Webview {
  final String uri;
  final FutureOr Function(Widget route) onNavigatorPush;
  final FutureOr<void> Function() onNavigatorPop;

  Webview({
    required this.onNavigatorPush,
    required this.onNavigatorPop,
    required this.uri,
  }) : _onUrlRequestStreamController = StreamController<String>.broadcast();

  StreamController<String>? _onUrlRequestStreamController;
  Stream<String> get onUrlRequestStream =>
      _onUrlRequestStreamController!.stream;

  webview_window.Webview? _webview;
  Future<void> open() async {
    if (Platform.isLinux) {
      final applicationSupportDir = await getApplicationSupportDirectory();
      final userDataFolder = Directory(
        join(applicationSupportDir.path, "webview_window_Webview2"),
      );

      if (!await userDataFolder.exists()) {
        await userDataFolder.create();
      }

      _webview = await WebviewWindow.create(
          configuration: CreateConfiguration(
            title: "Spotube Login",
            windowHeight: 720,
            windowWidth: 1280,
            userDataFolderWindows: userDataFolder.path,
          ),
        )
        ..setApplicationUserAgent(RandomUserAgents.random());
      _webview!.setOnUrlRequestCallback((url) {
        _onUrlRequestStreamController?.add(url);
        return true;
      });
      _webview!.launch(uri);

      return;
    }

    final route = WebviewPage(
      uri: uri,
      onLoad: (url) {
        _onUrlRequestStreamController?.add(url.toString());
      },
    );
    await onNavigatorPush(route);
  }

  Future<void> close() async {
    _onUrlRequestStreamController?.close();
    _onUrlRequestStreamController = null;
    if (Platform.isLinux) {
      _webview?.close();
      _webview = null;
      return;
    }
    await onNavigatorPop();
  }

  Future<List<Cookie>> getCookies(String url) async {
    if (Platform.isLinux) {
      final cookies = await _webview?.getAllCookies() ?? [];

      return cookies.map((cookie) {
        return Cookie(
          name: cookie.name,
          value: cookie.value,
          domain: cookie.domain,
          expiresDate: cookie.expires?.millisecondsSinceEpoch,
          isHttpOnly: cookie.httpOnly,
          isSecure: cookie.secure,
          isSessionOnly: cookie.sessionOnly,
          path: cookie.path,
        );
      }).toList();
    }

    final cookies = await CookieManager.instance(
      // Created in [WebviewPage]. Custom WebViewEnvironment for Windows otherwise it installs
      // in installation directory so permission exception occurs.
      webViewEnvironment: await webViewEnvironment,
    ).getCookies(url: WebUri(url));

    // Android's CookieManager does not return HttpOnly cookies, but Google's
    // auth cookies (SAPISID, SID, HSID, ...) are HttpOnly, so the login flow
    // would never see them there. Read them from the WebView's SQLite cookie
    // store and merge them in. Best-effort: any failure keeps the standard
    // (CookieManager) results.
    if (Platform.isAndroid) {
      try {
        final dbCookies = await _readAndroidWebViewCookies();
        if (dbCookies.isNotEmpty) {
          final seen = <String>{for (final c in cookies) c.name};
          for (final c in dbCookies) {
            final name = c.name;
            if (name.isNotEmpty && !seen.contains(name)) {
              cookies.add(c);
              seen.add(name);
            }
          }
        }
      } catch (error) {
        debugPrint('[Webview] Android cookie store read failed: $error');
      }
    }

    return cookies;
  }

  /// Reads the Android WebView cookie SQLite store to obtain the HttpOnly
  /// cookies that [CookieManager] refuses to expose. The DB (main + WAL + SHM)
  /// is copied to a temp dir first for a consistent snapshot. Returns [] on any
  /// failure (missing store, unsupported schema, busy DB, ...).
  Future<List<Cookie>> _readAndroidWebViewCookies() async {
    final appSupport = await getApplicationSupportDirectory();
    final webViewRoot = Directory(join(appSupport.parent.path, 'app_webview'));
    if (!await webViewRoot.exists()) return const [];

    final dbFile = await _findCookieStore(webViewRoot);
    if (dbFile == null) return const [];

    final tempDir = await Directory.systemTemp.createTemp('spotube_ytcookies');
    final copyPath = join(tempDir.path, 'Cookies');
    try {
      await _copyIfExists(dbFile, copyPath);
      await _copyIfExists(File('${dbFile.path}-wal'), '$copyPath-wal');
      await _copyIfExists(File('${dbFile.path}-shm'), '$copyPath-shm');

      final db = sqlite3.open(copyPath);
      try {
        final rows = db.select(
          'SELECT host_key, name, value, path, is_secure, is_httponly '
          "FROM cookies WHERE value != ''",
        );
        return rows.map((row) {
          return Cookie(
            name: (row['name'] as String? ?? '').trim(),
            value: (row['value'] as String? ?? ''),
            domain: (row['host_key'] as String? ?? '').trim(),
            path: (row['path'] as String? ?? '/'),
            isSecure: (row['is_secure'] as int? ?? 0) == 1,
            isHttpOnly: (row['is_httponly'] as int? ?? 0) == 1,
          );
        }).toList();
      } finally {
        db.dispose();
      }
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Finds the WebView "Cookies" sqlite file under [root]
  /// (e.g. `{dataDir}/app_webview/Default/Cookies`).
  Future<File?> _findCookieStore(Directory root) async {
    try {
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File && basename(entity.path) == 'Cookies') {
          return entity;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _copyIfExists(File src, String dest) async {
    if (await src.exists()) {
      await src.copy(dest);
    }
  }
}
