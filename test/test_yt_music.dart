// Standalone test for YtMusicEngine
// Run: fvm dart run test/test_yt_music.dart
import 'package:spotube/services/youtube_engine/yt_music_engine.dart';

void main() async {
  final videoId = 'dQw4w9WgXcQ'; // Rick Astley - Never Gonna Give You Up

  print('=== Testing YtMusicEngine ===');
  print('Video ID: $videoId');
  print('');

  final engine = YtMusicEngine();

  // Test 1: getVideo (metadata)
  print('--- Test 1: getVideo ---');
  try {
    final stopwatch = Stopwatch()..start();
    final video = await engine.getVideo(videoId);
    stopwatch.stop();
    print('  âœ… Success (${stopwatch.elapsed.inMilliseconds}ms)');
    print('  Title: ${video.title}');
    print('  Author: ${video.author}');
    print('  Duration: ${video.duration?.inSeconds ?? 0}s');
  } catch (e) {
    print('  âŒ Failed: $e');
  }
  print('');

  // Test 2: getStreamManifest (stream URLs)
  print('--- Test 2: getStreamManifest ---');
  try {
    final stopwatch = Stopwatch()..start();
    final manifest = await engine.getStreamManifest(videoId);
    stopwatch.stop();
    print('  âœ… Success (${stopwatch.elapsed.inMilliseconds}ms)');
    print('  Audio streams: ${manifest.audioOnly.length}');
    for (int i = 0; i < manifest.audioOnly.length && i < 3; i++) {
      final stream = manifest.audioOnly[i];
      print(
          '    [$i] ${stream.audioCodec} @ ${stream.bitrate.kiloBitsPerSecond}kbps - ${stream.url}');
    }
  } catch (e) {
    print('  âŒ Failed: $e');
  }
  print('');

  // Test 3: Test with another video ID
  final videoId2 = 'WcXRqzxQHF0';
  print('=== Testing with video: $videoId2 ===');
  print('--- Test: getStreamManifest ---');
  try {
    final stopwatch = Stopwatch()..start();
    final manifest = await engine.getStreamManifest(videoId2);
    stopwatch.stop();
    print('  âœ… Success (${stopwatch.elapsed.inMilliseconds}ms)');
    print('  Audio streams: ${manifest.audioOnly.length}');
    for (int i = 0; i < manifest.audioOnly.length && i < 3; i++) {
      final stream = manifest.audioOnly[i];
      print(
          '    [$i] ${stream.audioCodec} @ ${stream.bitrate.kiloBitsPerSecond}kbps - ${stream.url}');
    }
  } catch (e) {
    print('  âŒ Failed: $e');
  }

  engine.dispose();
  print('');
  print('=== Done ===');
}
