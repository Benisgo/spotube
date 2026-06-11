import 'package:spotube/services/youtube_engine/verome_engine.dart';
void main() async {
  final engine = VeromeEngine();
  try {
    final results = await engine.searchVideos('Never gonna give you up');
    print('Found ${results.length} results');
    if (results.isNotEmpty) {
      final video = results.first;
      print('First result: ${video.title} - ${video.author}');
      final streams = await engine.getStreamManifest(video.id.value);
      print('Found ${streams.audioOnly.length} audio streams');
    }
  } catch (e, stack) {
    print('Failed with $e');
    print(stack);
  } finally {
    engine.dispose();
  }
}
