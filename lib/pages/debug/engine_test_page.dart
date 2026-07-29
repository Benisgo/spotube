import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:spotube/services/youtube_engine/innertube_engine.dart';
import 'package:spotube/services/youtube_engine/invidious_engine.dart';
import 'package:spotube/services/youtube_engine/newpipe_engine.dart';
import 'package:spotube/services/youtube_engine/verome_engine.dart';
import 'package:spotube/services/youtube_engine/youtube_explode_engine.dart';
import 'package:spotube/services/youtube_engine/yt_music_engine.dart';
import 'package:spotube/services/youtube_engine/yt_dlp_engine.dart';
import 'package:spotube/services/youtube_engine/android_yt_dlp_engine.dart';
import 'package:spotube/utils/platform.dart';

class _TestResult {
  final String testName;
  final bool success;
  final Duration elapsed;
  final String? detail;
  const _TestResult({required this.testName, required this.success, required this.elapsed, this.detail});
}

typedef _EngineFactory = YouTubeEngine Function();

final _allEngines = <_EngineEntry>[
  _EngineEntry("InnerTube", () => InnerTubeEngine(), InnerTubeEngine.isAvailableForPlatform),
  _EngineEntry("YouTubeExplode", () => YouTubeExplodeEngine(), YouTubeExplodeEngine.isAvailableForPlatform),
  _EngineEntry("Invidious", () => InvidiousEngine(), InvidiousEngine.isAvailableForPlatform),
  _EngineEntry("NewPipe", () => NewPipeEngine(), NewPipeEngine.isAvailableForPlatform),
  _EngineEntry("Verome", () => VeromeEngine(), VeromeEngine.isAvailableForPlatform),
  _EngineEntry("YtDlp", () => YtDlpEngine(), YtDlpEngine.isAvailableForPlatform),
  if (kIsAndroid) _EngineEntry("AndroidYtDlp", () => AndroidYtDlpEngine(), AndroidYtDlpEngine.isAvailableForPlatform),
  _EngineEntry("YouTube Music", () => YtMusicEngine(), YtMusicEngine.isAvailableForPlatform),
];

@RoutePage()
class DebugEngineTestPage extends HookConsumerWidget {
  const DebugEngineTestPage({super.key});

  @override
  Widget build(BuildContext context, ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Engine Tester"),
          bottom: const TabBar(tabs: [
            Tab(text: "Video ID", icon: Icon(Icons.play_arrow)),
            Tab(text: "Search", icon: Icon(Icons.search)),
          ]),
        ),
        body: const TabBarView(children: [
          _VideoTestTab(), _SearchTestTab(),
        ]),
      ),
    );
  }
}

class _VideoTestTab extends HookConsumerWidget {
  const _VideoTestTab();
  @override
  Widget build(BuildContext context, ref) {
    final c = useTextEditingController(text: "dQw4w9WgXcQ");
    final r = useState<Map<String, List<_TestResult>>>({});
    final b = useState<Set<String>>({});
    Future<void> t(_EngineEntry e) async {
      final id = _extractId(c.text); if (id.isEmpty) return;
      b.value = {...b.value, e.name}; final l = <_TestResult>[];
      await _runTest(e.factory, "getVideo", id, l, (x) => x.getVideo(id));
      await _runTest(e.factory, "getStreamManifest", id, l, (x) => x.getStreamManifest(id));
      r.value = {...r.value, e.name: l}; b.value = b.value.difference({e.name});
    }
    return _buildTab(c, r.value, b.value, t, hint: "Video ID or URL");
  }
}

class _SearchTestTab extends HookConsumerWidget {
  const _SearchTestTab();
  @override
  Widget build(BuildContext context, ref) {
    final c = useTextEditingController(text: "Rick Astley Never Gonna Give You Up");
    final r = useState<Map<String, List<_TestResult>>>({});
    final b = useState<Set<String>>({});
    Future<void> t(_EngineEntry e) async {
      final q = c.text.trim(); if (q.isEmpty) return;
      b.value = {...b.value, e.name}; final l = <_TestResult>[];
      await _runTest(e.factory, "search", q, l, (x) => x.searchVideos(q));
      r.value = {...r.value, e.name: l}; b.value = b.value.difference({e.name});
    }
    return _buildTab(c, r.value, b.value, t, hint: "Search query");
  }
}

class _EngineEntry {
  final String name; final _EngineFactory factory; final bool available;
  const _EngineEntry(this.name, this.factory, this.available);
}

String _extractId(String text) {
  final t = text.trim();
  if (t.contains("youtube.com/watch?v=")) { final u = Uri.tryParse(t); if (u != null) return u.queryParameters["v"] ?? t; }
  else if (t.contains("youtu.be/")) return t.split("youtu.be/").last.split("?").first;
  return t;
}

Widget _buildTab(TextEditingController c, Map<String, List<_TestResult>> r, Set<String> b, Future<void> Function(_EngineEntry) t, {required String hint}) {
  return Column(children: [
    Padding(padding: const EdgeInsets.all(16), child: TextField(controller: c, decoration: InputDecoration(labelText: hint, hintText: "e.g. dQw4w9WgXcQ", border: const OutlineInputBorder(), isDense: true))),
    Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 160), children: [
      for (final e in _allEngines.where((x) => x.available))
        _EngineCard(name: e.name, testResults: r[e.name] ?? const [], isRunning: b.contains(e.name), onTest: () => t(e)),
    ])),
  ]);
}

Future<void> _runTest(_EngineFactory f, String n, String i, List<_TestResult> r, Future<Object?> Function(YouTubeEngine) fn) async {
  final e = f(); final sw = Stopwatch()..start();
  try { final v = await fn(e).timeout(const Duration(seconds: 15)); sw.stop();
    r.add(_TestResult(testName: n, success: true, elapsed: sw.elapsed, detail: v?.toString().substring(0, v.toString().length.clamp(0, 120)))); }
  catch (ex) { sw.stop(); r.add(_TestResult(testName: n, success: false, elapsed: sw.elapsed, detail: ex.toString())); }
  finally { e.dispose(); }
}

class _EngineCard extends StatelessWidget {
  final String name; final List<_TestResult> testResults; final bool isRunning; final VoidCallback onTest;
  const _EngineCard({required this.name, required this.testResults, required this.isRunning, required this.onTest});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(margin: const EdgeInsets.only(bottom: 12), child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(name, style: t.textTheme.titleMedium)),
        if (isRunning) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 8), TextButton(onPressed: isRunning ? null : onTest, child: const Text("Test")),
      ]),
      const SizedBox(height: 8),
      if (testResults.isEmpty) Text("Not tested yet", style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurface.withValues(alpha: 0.5))),
      for (final r in testResults) Padding(padding: const EdgeInsets.only(top: 4), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(r.success ? Icons.check_circle : Icons.error, size: 16, color: r.success ? Colors.green : Colors.red),
          const SizedBox(width: 8),
          Text("${r.testName} (${r.elapsed.inMilliseconds}ms)", style: t.textTheme.bodySmall),
        ]),
        if (r.detail != null) Padding(padding: const EdgeInsets.only(left: 24, top: 2), child: Text(r.detail!, style: t.textTheme.bodySmall?.copyWith(fontSize: 11, color: r.success ? t.colorScheme.onSurface.withValues(alpha: 0.7) : Colors.red.shade300), maxLines: 5, overflow: TextOverflow.ellipsis)),
      ])),
    ])));
  }
}
