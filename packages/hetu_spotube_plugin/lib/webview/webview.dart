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
        // Chromium batches cookie writes and commits to the SQLite store every
        // ~30s; the plugin retries reading for ~40s (plugin.ht) so the freshly
        // issued auth cookies land on disk within that window.
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
    // Modern Android System WebView stores the cookie DB under
    // <dataDir>/Default/Cookies (profiles may be hash-named); the legacy
    // location was <dataDir>/app_webview/... . Search the app data root and
    // prefer the default profile's store.
    final dataDir = appSupport.parent;
    if (!await dataDir.exists()) return const [];

    final dbFile = await _findCookieStore(dataDir);
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
    // Search only the WebView profile dirs directly under the app data root
    // (Default, hash-named, "Profile N") plus the legacy app_webview location.
    // We deliberately do NOT recurse into files/ or cache/ (which can be large
    // on a media app) — the cookie DB always lives at a top-level profile dir.
    try {
      final defaultCookies = File(join(root.path, 'Default', 'Cookies'));
      if (await defaultCookies.exists()) return defaultCookies;

      final legacy = File(join(root.path, 'app_webview', 'Default', 'Cookies'));
      if (await legacy.exists()) return legacy;

      await for (final entity in root.list(followLinks: false)) {
        if (entity is Directory) {
          final candidate = File(join(entity.path, 'Cookies'));
          if (await candidate.exists()) return candidate;
          final nestedDefault = File(join(entity.path, 'Default', 'Cookies'));
          if (await nestedDefault.exists()) return nestedDefault;
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
