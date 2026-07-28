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

class _EngineTestResult {
  final String engineName;
  final String testName;
  final bool success;
  final Duration elapsed;
  final String? detail;
  const _EngineTestResult({
    required this.engineName,
    required this.testName,
    required this.success,
    required this.elapsed,
    this.detail,
  });
}

class _EngineTester {
  final String name;
  final YouTubeEngine Function() factory;
  final bool Function() isAvailable;
  const _EngineTester({
    required this.name,
    required this.factory,
    required this.isAvailable,
  });
}

List<_EngineTester> _allTesters() => [
      _EngineTester(
        name: 'InnerTube',
        factory: () => InnerTubeEngine(),
        isAvailable: () => InnerTubeEngine.isAvailableForPlatform,
      ),
      _EngineTester(
        name: 'YouTubeExplode',
        factory: () => YouTubeExplodeEngine(),
        isAvailable: () => YouTubeExplodeEngine.isAvailableForPlatform,
      ),
      _EngineTester(
        name: 'Invidious',
        factory: () => InvidiousEngine(),
        isAvailable: () => InvidiousEngine.isAvailableForPlatform,
      ),
      _EngineTester(
        name: 'NewPipe',
        factory: () => NewPipeEngine(),
        isAvailable: () => NewPipeEngine.isAvailableForPlatform,
      ),
      _EngineTester(
        name: 'Verome',
        factory: () => VeromeEngine(),
        isAvailable: () => VeromeEngine.isAvailableForPlatform,
      ),
      _EngineTester(
        name: 'YtDlp',
        factory: () => YtDlpEngine(),
        isAvailable: () => YtDlpEngine.isAvailableForPlatform,
      ),
      if (kIsAndroid)
        _EngineTester(
          name: 'AndroidYtDlp',
          factory: () => AndroidYtDlpEngine(),
          isAvailable: () => AndroidYtDlpEngine.isAvailableForPlatform,
        ),
      _EngineTester(
        name: 'YouTube Music',
        factory: () => YtMusicEngine(),
        isAvailable: () => YtMusicEngine.isAvailableForPlatform,
      ),
    ];

@RoutePage()
class DebugEngineTestPage extends HookConsumerWidget {
  const DebugEngineTestPage({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final videoIdController = useTextEditingController(text: 'dQw4w9WgXcQ');
    final results = useState<List<_EngineTestResult>>(const []);
    final running = useState<Set<String>>({});

    Future<void> _testAll() async {
      final videoId = videoIdController.text.trim();
      if (videoId.isEmpty) return;
      final testers = _allTesters().where((t) => t.isAvailable()).toList();
      final newResults = <_EngineTestResult>[];
      results.value = [];
      for (final tester in testers) {
        running.value = {...running.value, tester.name};
        await _runTest(tester, 'getVideo', videoId, newResults,
            (engine) => engine.getVideo(videoId));
        await _runTest(tester, 'getStreamManifest', videoId, newResults,
            (engine) => engine.getStreamManifest(videoId));
        running.value = running.value.difference({tester.name});
        results.value = List.of(newResults);
      }
    }

    Future<void> _testSingle(_EngineTester tester) async {
      final videoId = videoIdController.text.trim();
      if (videoId.isEmpty) return;
      running.value = {...running.value, tester.name};
      final newResults = List<_EngineTestResult>.of(results.value);
      await _runTest(tester, 'getVideo', videoId, newResults,
          (engine) => engine.getVideo(videoId));
      await _runTest(tester, 'getStreamManifest', videoId, newResults,
          (engine) => engine.getStreamManifest(videoId));
      running.value = running.value.difference({tester.name});
      results.value = newResults;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('YouTube Engine Tester'),
        actions: [
          TextButton(
            onPressed: running.value.isNotEmpty ? null : _testAll,
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
                  child: const Text('Extract ID'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final tester
                    in _allTesters().where((t) => t.isAvailable()))
                  _EngineCard(
                    tester: tester,
                    results: results.value
                        .where((r) => r.engineName == tester.name)
                        .toList(),
                    isRunning: running.value.contains(tester.name),
                    onTest: () => _testSingle(tester),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _runTest(
    _EngineTester tester,
    String testName,
    String videoId,
    List<_EngineTestResult> results,
    Future<Object?> Function(YouTubeEngine engine) testFn,
  ) async {
    final engine = tester.factory();
    final stopwatch = Stopwatch()..start();
    try {
      final result =
          await testFn(engine).timeout(const Duration(seconds: 15));
      stopwatch.stop();
      results.add(_EngineTestResult(
        engineName: tester.name,
        testName: testName,
        success: true,
        elapsed: stopwatch.elapsed,
        detail: result?.toString().substring(0, 100),
      ));
    } catch (e) {
      stopwatch.stop();
      results.add(_EngineTestResult(
        engineName: tester.name,
        testName: testName,
        success: false,
        elapsed: stopwatch.elapsed,
        detail: e.toString().substring(0, 200),
      ));
    } finally {
      engine.dispose();
    }
  }
}

class _EngineCard extends StatelessWidget {
  final _EngineTester tester;
  final List<_EngineTestResult> results;
  final bool isRunning;
  final VoidCallback onTest;
  const _EngineCard({
    required this.tester,
    required this.results,
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
                  child: Text(tester.name,
                      style: theme.textTheme.titleMedium),
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
            if (results.isEmpty)
              Text(
                'Not tested yet',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            for (final result in results)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Icon(
                      result.success ? Icons.check_circle : Icons.error,
                      size: 16,
                      color: result.success ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${result.testName} (${result.elapsed.inMilliseconds}ms)',
                      style: theme.textTheme.bodySmall,
                    ),
                    if (result.detail != null) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          result.detail!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.5),
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
