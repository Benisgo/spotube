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
  const _TestResult({
    required this.testName,
    required this.success,
    required this.elapsed,
    this.detail,
  });
}

typedef _EngineFactory = YouTubeEngine Function();

@RoutePage()
class DebugEngineTestPage extends HookConsumerWidget {
  const DebugEngineTestPage({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final videoIdController = useTextEditingController(text: 'dQw4w9WgXcQ');
    final results = useState<Map<String, List<_TestResult>>>({});
    final running = useState<Set<String>>({});

    // Explicit engine list - add new engines here
    final engines = <_EngineEntry>[
      _EngineEntry('InnerTube', () => InnerTubeEngine(),
          InnerTubeEngine.isAvailableForPlatform),
      _EngineEntry('YouTubeExplode', () => YouTubeExplodeEngine(),
          YouTubeExplodeEngine.isAvailableForPlatform),
      _EngineEntry('Invidious', () => InvidiousEngine(),
          InvidiousEngine.isAvailableForPlatform),
      _EngineEntry('NewPipe', () => NewPipeEngine(),
          NewPipeEngine.isAvailableForPlatform),
      _EngineEntry('Verome', () => VeromeEngine(),
          VeromeEngine.isAvailableForPlatform),
      _EngineEntry('YtDlp', () => YtDlpEngine(),
          YtDlpEngine.isAvailableForPlatform),
      if (kIsAndroid)
        _EngineEntry('AndroidYtDlp', () => AndroidYtDlpEngine(),
            AndroidYtDlpEngine.isAvailableForPlatform),
      _EngineEntry('YouTube Music', () => YtMusicEngine(),
          YtMusicEngine.isAvailableForPlatform),
    ];

    Future<void> testEngine(_EngineEntry entry) async {
      final videoId = videoIdController.text.trim();
      if (videoId.isEmpty) return;

      running.value = {...running.value, entry.name};
      final list = <_TestResult>[];

      await _runTest(entry.factory, 'getVideo', videoId, list,
          (e) => e.getVideo(videoId));
      await _runTest(entry.factory, 'getStreamManifest', videoId, list,
          (e) => e.getStreamManifest(videoId));

      results.value = {...results.value, entry.name: list};
      running.value = running.value.difference({entry.name});
    }

    Future<void> testAll() async {
      final videoId = videoIdController.text.trim();
      if (videoId.isEmpty) return;
      for (final entry in engines.where((e) => e.available)) {
        await testEngine(entry);
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('YouTube Engine Tester'),
        actions: [
          TextButton(
            onPressed: running.value.isNotEmpty ? null : testAll,
            child: const Text('Test All'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: videoIdController,
                    decoration: const InputDecoration(
                      labelText: 'Video ID or URL',
                      hintText: 'e.g. dQw4w9WgXcQ',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    final text = videoIdController.text.trim();
                    if (text.contains('youtube.com/watch?v=')) {
                      final uri = Uri.tryParse(text);
                      if (uri != null) {
                        videoIdController.text =
                            uri.queryParameters['v'] ?? text;
                      }
                    } else if (text.contains('youtu.be/')) {
                      videoIdController.text =
                          text.split('youtu.be/').last.split('?').first;
                    }
                  },
                  child: const Text('Extract'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final entry in engines.where((e) => e.available))
                  _EngineCard(
                    name: entry.name,
                    testResults: results.value[entry.name] ?? const [],
                    isRunning: running.value.contains(entry.name),
                    onTest: () => testEngine(entry),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _runTest(
    _EngineFactory factory,
    String testName,
    String videoId,
    List<_TestResult> results,
    Future<Object?> Function(YouTubeEngine engine) testFn,
  ) async {
    final engine = factory();
    final stopwatch = Stopwatch()..start();
    try {
      final result = await testFn(engine).timeout(const Duration(seconds: 15));
      stopwatch.stop();
      results.add(_TestResult(
        testName: testName,
        success: true,
        elapsed: stopwatch.elapsed,
        detail: result?.toString().substring(0, 150),
      ));
    } catch (e) {
      stopwatch.stop();
      results.add(_TestResult(
        testName: testName,
        success: false,
        elapsed: stopwatch.elapsed,
        detail: e.toString().substring(0, 300),
      ));
    } finally {
      engine.dispose();
    }
  }
}

class _EngineEntry {
  final String name;
  final _EngineFactory factory;
  final bool available;
  const _EngineEntry(this.name, this.factory, this.available);
}

class _EngineCard extends StatelessWidget {
  final String name;
  final List<_TestResult> testResults;
  final bool isRunning;
  final VoidCallback onTest;

  const _EngineCard({
    required this.name,
    required this.testResults,
    required this.isRunning,
    required this.onTest,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(name, style: theme.textTheme.titleMedium),
                ),
                if (isRunning)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: isRunning ? null : onTest,
                  child: const Text('Test'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (testResults.isEmpty)
              Text(
                'Not tested yet',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            for (final result in testResults)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          result.success
                              ? Icons.check_circle
                              : Icons.error,
                          size: 16,
                          color: result.success ? Colors.green : Colors.red,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '${result.testName} (${result.elapsed.inMilliseconds}ms)${result.success ? " OK" : " FAIL"}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                    if (result.detail != null && !result.success)
                      Padding(
                        padding: const EdgeInsets.only(left: 24, top: 2),
                        child: Text(
                          result.detail!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.red.shade300,
                            fontSize: 11,
                          ),
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
