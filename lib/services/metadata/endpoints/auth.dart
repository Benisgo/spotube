import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hetu_script/hetu_script.dart';
import 'package:hetu_script/values.dart';
import 'package:hetu_std/hetu_std.dart';
import 'package:spotube/utils/platform.dart';

class MetadataAuthEndpoint {
  final Hetu hetu;

  MetadataAuthEndpoint(this.hetu);

  HTInstance get _hetuMetadataAuth =>
      (hetu.fetch("metadataPlugin") as HTInstance).memberGet("auth")
          as HTInstance;

  Stream get authStateStream =>
      _hetuMetadataAuth.memberGet("authStateStream") as Stream;

  Future<void> authenticate() async {
    await _hetuMetadataAuth.invoke("authenticate");
  }

  bool isAuthenticated() {
    return _hetuMetadataAuth.invoke("isAuthenticated") as bool;
  }

  Future<void> logout() async {
    await _hetuMetadataAuth.invoke("logout");
    if (kIsMobile) {
      WebStorageManager.instance().deleteAllData();
      CookieManager.instance().deleteAllCookies();
    }
    if (kIsDesktop) {
      await WebviewWindow.clearAll();
    }
  }
}
