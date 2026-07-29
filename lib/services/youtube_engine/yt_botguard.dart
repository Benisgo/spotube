import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:spotube/services/logger/logger.dart';

/// BotGuard poToken attestation for the WEB InnerTube client.
///
/// Mirrors Flow's PoTokenWebView + PoTokenGenerator approach.
/// All methods gracefully return null on failure (existing engine continues).
class YouTubeBotGuard {
  YouTubeBotGuard._();

  // ── Constants (from Flow) ───────────────────────────────────────
  static const String _apiKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw";
  static const String _requestKey = "O43z0dpjhgX20SCx4KAo";
  static const String _userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
      "AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/131.0.0.0 Safari/537.36";

  // ── State ───────────────────────────────────────────────────────
  static HeadlessInAppWebView? _webView;
  static InAppWebViewController? _controller;
  static bool _initialized = false;
  static String? _cachedVisitorData;

  /// Completer that resolves when the poToken minter is ready in JS.
  static Completer<void>? _minterReady;
  static bool _minterReadyCompleted = false;

  /// Pending mint completers: videoId -> Completer<String?>
  static final Map<String, Completer<String?>> _pendingMintCompleters = {};

  // ── Visitor Data ────────────────────────────────────────────────

  /// Fetch visitorData from YouTube's sw.js_data endpoint.
  /// YouTube may change this format; returns null on any failure.
  static Future<String?> fetchVisitorData() async {
    if (_cachedVisitorData != null) return _cachedVisitorData;
    try {
      final resp = await http.get(
        Uri.parse("https://music.youtube.com/sw.js_data"),
        headers: {"User-Agent": _userAgent},
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final body = resp.body;
      if (body.length < 5) return null;
      final json = jsonDecode(body.substring(5));
      final arr = (json as List?)?.elementAtOrNull(0) as List?;
      final candidates = arr?.elementAtOrNull(2) as List?;
      if (candidates == null) return null;
      for (final c in candidates) {
        if (c is String && RegExp(r'^Cg[ts]').hasMatch(c)) {
          _cachedVisitorData = c;
          return c;
        }
      }
    } catch (e) {
      AppLogger.log.w("[yt_botguard] fetchVisitorData failed: $e");
    }
    return null;
  }

  // ── Initialization ──────────────────────────────────────────────

  /// Initialize BotGuard: create hidden WebView, load BotGuard JS,
  /// fetch challenge, run interpreter, generate integrity token, create minter.
  static Future<bool> initialize({WebViewEnvironment? environment}) async {
    if (_initialized) return true;

    try {
      final visitorData = await fetchVisitorData();
      if (visitorData == null) {
        AppLogger.log.w("[yt_botguard] no visitorData, aborting init");
        return false;
      }

      _webView = HeadlessInAppWebView(
        initialData: InAppWebViewInitialData(
          data: _buildBotGuardHtml(),
          baseUrl: WebUri("https://www.youtube.com"),
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          userAgent: _userAgent,
        ),
        webViewEnvironment: environment,
        onLoadStop: (controller, url) async {
          AppLogger.log.i("[yt_botguard] page loaded, registering handlers");
          // Register handlers NOW — controller is guaranteed valid
          _registerHandlers(controller);
          // Trigger BotGuard AFTER handlers are registered (no race)
          await controller.evaluateJavascript(source: """
            window.flutter_inappwebview.callHandler('downloadAndRunBotguard');
          """);
        },
      );

      await _webView!.run();
      _controller = _webView!.webViewController;
      AppLogger.log.i("[yt_botguard] HeadlessInAppWebView running");

      _minterReady = Completer<void>();
      _minterReadyCompleted = false;
      _initialized = true;
      return true;
    } catch (e) {
      AppLogger.log.w("[yt_botguard] initialize failed: $e");
      await dispose();
      return false;
    }
  }

  // ── Minting ─────────────────────────────────────────────────────

  /// Mint a poToken for the given videoId.
  /// Returns base64 poToken string, or null on failure.
  static Future<String?> mintPoToken(String videoId) async {
    if (!_initialized) {
      final ok = await initialize();
      if (!ok) return null;
    }

    // Wait for the minter to be created
    if (!_minterReadyCompleted && _minterReady != null) {
      try {
        await _minterReady!.future.timeout(const Duration(seconds: 30));
      } catch (_) {
        AppLogger.log.w("[yt_botguard] minter not ready within timeout");
        return null;
      }
    }

    if (_controller == null) return null;

    final completer = Completer<String?>();
    _pendingMintCompleters[videoId] = completer;

    final safeVideoId = jsonEncode(videoId);
    try {
      await _controller!.evaluateJavascript(source: """
        try {
          var enc = new TextEncoder();
          var u8Identifier = enc.encode($safeVideoId);
          obtainPoToken(u8Identifier).then(function(poTokenU8) {
            var bytes = new Uint8Array(poTokenU8);
            var binary = '';
            for (var i = 0; i < bytes.length; i++) { binary += String.fromCharCode(bytes[i]); }
            var base64 = btoa(binary);
            window.flutter_inappwebview.callHandler('onObtainPoTokenResult', $safeVideoId, base64);
          }).catch(function(error) {
            window.flutter_inappwebview.callHandler('onObtainPoTokenError', $safeVideoId, error.toString());
          });
        } catch (error) {
          window.flutter_inappwebview.callHandler('onObtainPoTokenError', $safeVideoId, error.toString());
        }
      """);
    } catch (e) {
      _pendingMintCompleters.remove(videoId);
      if (!completer.isCompleted) completer.complete(null);
      return null;
    }

    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _pendingMintCompleters.remove(videoId);
        if (!completer.isCompleted) completer.complete(null);
        return null;
      },
    );
  }

  /// Mint with a bounded timeout (fast path for first playback).
  static Future<String?> mintPoTokenBounded(
    String videoId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final completer = Completer<String?>();
    final result = await Future.any([
      mintPoToken(videoId).then((v) {
        if (!completer.isCompleted) completer.complete(v);
        return v;
      }),
      Future.delayed(timeout, () {
        if (!completer.isCompleted) {
          _pendingMintCompleters.remove(videoId);
          completer.complete(null);
        }
        return null;
      }),
    ]);
    return result;
  }

  // ── Cleanup ─────────────────────────────────────────────────────

  /// Clean up the hidden WebView.
  static Future<void> dispose() async {
    _initialized = false;
    _minterReady = null;
    _minterReadyCompleted = false;
    try {
      await _controller?.evaluateJavascript(
          source: "poTokenMinter = null; bgVm = null; window._bgWebPoSignalOutput = null;");
    } catch (_) {}
    try {
      await _webView?.dispose();
    } catch (_) {}
    _webView = null;
    _controller = null;
    for (final entry in _pendingMintCompleters.entries) {
      if (!entry.value.isCompleted) entry.value.complete(null);
    }
    _pendingMintCompleters.clear();
  }

  // ── JS -> Dart handlers ──────────────────────────────────────────

  static Future<void> _onDownloadAndRunBotguard() async {
    AppLogger.log.i("[yt_botguard] downloadAndRunBotguard called from JS");
    try {
      final challengeResp = await http
          .post(
            Uri.parse("https://www.youtube.com/api/jnn/v1/Create"),
            headers: {
              "User-Agent": _userAgent,
              "Content-Type": "application/json+protobuf",
              "x-goog-api-key": _apiKey,
            },
            body: jsonEncode([_requestKey]),
          )
          .timeout(const Duration(seconds: 15));

      if (challengeResp.statusCode != 200) {
        AppLogger.log
            .w("[yt_botguard] challenge HTTP ${challengeResp.statusCode}");
        await _jsCallback(
            "onJsInitializationError", ["BotGuard challenge failed"]);
        return;
      }

      // Parse: API returns [null, "<scrambled_base64>"]
      final respData = jsonDecode(challengeResp.body) as List;
      final scrambled = respData.length > 1 ? respData[1] as String? : null;
      if (scrambled == null || scrambled.isEmpty) {
        await _jsCallback("onJsInitializationError", ["No challenge data"]);
        return;
      }

      // Descramble: base64 decode + add 97 (Flow's parseChallengeData)
      final raw = base64.decode(_padBase64(scrambled));
      final descrambled = utf8.decode(
        raw.map((b) => (b + 97) & 0xFF).toList(),
      );
      final cd = jsonDecode(descrambled) as List;

      // Extract challenge fields: [msgId, interpreterJs, trustedUrl, hash, program, globalName, ?, clientBlob]
      final messageId = cd[0] as String;
      String? interpreterJs;
      if (cd.length > 1 && cd[1] is List) {
        for (final item in cd[1] as List) {
          if (item is String && item.isNotEmpty) {
            interpreterJs = item;
            break;
          }
        }
      }
      String? trustedUrl;
      if (cd.length > 2 && cd[2] is List) {
        for (final item in cd[2] as List) {
          if (item is String && item.isNotEmpty) {
            trustedUrl = item;
            break;
          }
        }
      }
      final interpreterHash = cd.length > 3 ? cd[3] as String : "";
      final program = cd.length > 4 ? cd[4] as String : "";
      final globalName = cd.length > 5 ? cd[5] as String : "";
      final clientBlob = cd.length > 7 ? cd[7] as String : "";

      await _controller?.evaluateJavascript(source: """
        try {
          var challengeData = {
            messageId: ${jsonEncode(messageId)},
            interpreterJavascript: {
              privateDoNotAccessOrElseSafeScriptWrappedValue: ${jsonEncode(interpreterJs)},
              privateDoNotAccessOrElseTrustedResourceUrlWrappedValue: ${jsonEncode(trustedUrl)}
            },
            interpreterHash: ${jsonEncode(interpreterHash)},
            program: ${jsonEncode(program)},
            globalName: ${jsonEncode(globalName)},
            clientExperimentsStateBlob: ${jsonEncode(clientBlob)}
          };
          runBotGuard(challengeData).then(function(result) {
            window._bgWebPoSignalOutput = result.webPoSignalOutput;
            window.flutter_inappwebview.callHandler(
              'onRunBotguardResult',
              result.botguardResponse
            );
          }).catch(function(error) {
            window.flutter_inappwebview.callHandler('onJsInitializationError', error.toString());
          });
        } catch (error) {
          window.flutter_inappwebview.callHandler('onJsInitializationError', error.toString());
        }
      """);
    } catch (e) {
      AppLogger.log.w("[yt_botguard] challenge fetch threw: $e");
      await _jsCallback("onJsInitializationError", [e.toString()]);
    }
  }

  static Future<void> _onRunBotguardResult(String botguardResponse) async {
    AppLogger.log.i("[yt_botguard] runBotGuard completed");

    try {
      final itResp = await http
          .post(
            Uri.parse("https://www.youtube.com/api/jnn/v1/GenerateIT"),
            headers: {
              "User-Agent": _userAgent,
              "Content-Type": "application/json+protobuf",
              "x-goog-api-key": _apiKey,
            },
            body: jsonEncode([_requestKey, botguardResponse]),
          )
          .timeout(const Duration(seconds: 15));

      if (itResp.statusCode != 200) {
        AppLogger.log.w("[yt_botguard] GenerateIT HTTP ${itResp.statusCode}");
        await _jsCallback("onJsInitializationError", ["GenerateIT failed"]);
        return;
      }

      final itData = jsonDecode(itResp.body) as List;
      final tokenB64 = itData[0] as String;

      final tokenBytes = base64.decode(tokenB64);
      final u8ArrayStr = "new Uint8Array([${tokenBytes.join(",")}])";

      await _controller?.evaluateJavascript(source: """
        try {
          var webPoSignalOutput = window._bgWebPoSignalOutput;
          window._bgWebPoSignalOutput = null;
          var integrityToken = $u8ArrayStr;
          createPoTokenMinter(webPoSignalOutput, integrityToken).then(function() {
            window.flutter_inappwebview.callHandler('onMinterCreated');
          }).catch(function(error) {
            window.flutter_inappwebview.callHandler('onJsInitializationError', error.toString());
          });
        } catch (error) {
          window.flutter_inappwebview.callHandler('onJsInitializationError', error.toString());
        }
      """);
    } catch (e) {
      AppLogger.log.w("[yt_botguard] GenerateIT threw: $e");
      await _jsCallback("onJsInitializationError", [e.toString()]);
    }
  }

  static void _onMinterCreated() {
    AppLogger.log.i("[yt_botguard] minter created successfully");
    if (!_minterReadyCompleted && _minterReady != null) {
      _minterReadyCompleted = true;
      _minterReady!.complete();
    }
  }

  static void _onJsError(String error) {
    AppLogger.log.w("[yt_botguard] JS error: $error");
  }

  static void _onObtainPoTokenResult(String videoId, String poToken) {
    final completer = _pendingMintCompleters.remove(videoId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(poToken);
    }
  }

  static void _onObtainPoTokenError(String videoId, String error) {
    AppLogger.log.w("[yt_botguard] mint error for $videoId: $error");
    final completer = _pendingMintCompleters.remove(videoId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(null);
    }
  }

  /// Register all JS -> Dart handlers on a controller.
  static void _registerHandlers(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: "downloadAndRunBotguard",
      callback: (_) => _onDownloadAndRunBotguard(),
    );
    controller.addJavaScriptHandler(
      handlerName: "onRunBotguardResult",
      callback: (args) => _onRunBotguardResult(
        args[0] as String,
      ),
    );
    controller.addJavaScriptHandler(
      handlerName: "onMinterCreated",
      callback: (_) => _onMinterCreated(),
    );
    controller.addJavaScriptHandler(
      handlerName: "onJsInitializationError",
      callback: (args) =>
          _onJsError(args.isNotEmpty ? args.first as String : "unknown"),
    );
    controller.addJavaScriptHandler(
      handlerName: "onObtainPoTokenResult",
      callback: (args) => _onObtainPoTokenResult(
        args[0] as String,
        args[1] as String,
      ),
    );
    controller.addJavaScriptHandler(
      handlerName: "onObtainPoTokenError",
      callback: (args) => _onObtainPoTokenError(
        args[0] as String,
        args.length > 1 ? args[1] as String : "unknown error",
      ),
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────

  static Future<void> _jsCallback(String handler, List<dynamic> args) async {
    try {
      final encoded = args.map((a) => jsonEncode(a)).join(",");
      await _controller?.evaluateJavascript(source: """
        window.flutter_inappwebview.callHandler('$handler', $encoded);
      """);
    } catch (_) {}
  }

  /// Pad base64 string to correct length.
  static String _padBase64(String s) {
    switch (s.length % 4) {
      case 2:
        return "${s}==";
      case 3:
        return "${s}=";
      default:
        return s;
    }
  }

  static String _buildBotGuardHtml() {
    return '''
<!DOCTYPE html>
<html lang="en"><head><title></title><script>
var bgVmFunctions = null;
var bgVm = null;
var bgProgram = null;
var poTokenMinter = null;

function loadBotGuard(challengeData) {
  bgVm = window[challengeData.globalName];
  bgProgram = challengeData.program;
  bgVmFunctions = null;
  if (!bgVm) throw new Error('[BotGuardClient]: VM not found');
  if (!bgVm.a) throw new Error('[BotGuardClient]: Could not load program');
  var vmFunctionsCallback = function(
    asyncSnapshotFunction, shutdownFunction, passEventFunction, checkCameraFunction
  ) {
    bgVmFunctions = {
      asyncSnapshotFunction: asyncSnapshotFunction,
      shutdownFunction: shutdownFunction,
      passEventFunction: passEventFunction,
      checkCameraFunction: checkCameraFunction
    };
  };
  try {
    bgVm.a(bgProgram, vmFunctionsCallback, true, undefined, function(){}, [[],[]]);
  } catch(e) {
    throw new Error('[BotGuardClient]: Failed to execute program: ' + e.message);
  }
  return new Promise(function(resolve, reject) {
    var attempts = 0;
    var maxAttempts = 10000;
    var checkInterval = setInterval(function() {
      if (bgVmFunctions && bgVmFunctions.asyncSnapshotFunction) {
        clearInterval(checkInterval);
        resolve({ vmFunctions: bgVmFunctions, vm: bgVm, program: bgProgram });
      } else if (attempts >= maxAttempts) {
        clearInterval(checkInterval);
        reject(new Error('[BotGuardClient]: Timeout waiting for asyncSnapshotFunction'));
      }
      attempts++;
    }, 1);
  });
}

function snapshot(botguard, args) {
  return new Promise(function(resolve, reject) {
    if (!botguard.vmFunctions || !botguard.vmFunctions.asyncSnapshotFunction) {
      return reject(new Error('[BotGuardClient]: Async snapshot function not found'));
    }
    try {
      botguard.vmFunctions.asyncSnapshotFunction(
        function(response) { resolve(response); },
        [args.contentBinding, args.signedTimestamp, args.webPoSignalOutput, args.skipPrivacyBuffer]
      );
    } catch(e) {
      reject(new Error('[BotGuardClient]: Snapshot failed: ' + e.message));
    }
  });
}

function runBotGuard(challengeData) {
  var intJs = challengeData.interpreterJavascript.privateDoNotAccessOrElseSafeScriptWrappedValue;
  if (intJs) { new Function(intJs)(); } else { throw new Error('[BotGuardClient]: No interpreter JS'); }
  var webPoSignalOutput = [];
  return loadBotGuard({ globalName: challengeData.globalName, program: challengeData.program }).then(function(botguard) {
    return snapshot(botguard, { webPoSignalOutput: webPoSignalOutput });
  }).then(function(botguardResponse) {
    return { webPoSignalOutput: webPoSignalOutput, botguardResponse: botguardResponse };
  });
}

async function createPoTokenMinter(webPoSignalOutput, integrityToken) {
  var getMinter = webPoSignalOutput[0];
  if (!getMinter) throw new Error('PMD:Undefined');
  var mintCallback = getMinter(integrityToken);
  if (mintCallback && typeof mintCallback.then === 'function') { mintCallback = await mintCallback; }
  if (!mintCallback) throw new Error('APF:Undefined');
  if (typeof mintCallback !== 'function') throw new Error('APF:NotFunction');
  poTokenMinter = mintCallback;
}

async function obtainPoToken(identifier) {
  if (!poTokenMinter) throw new Error('MNT:NotInit');
  var result = poTokenMinter(identifier);
  if (result && typeof result.then === 'function') { result = await result; }
  return result;
}

</script></head><body></body></html>
''';
  }
}
