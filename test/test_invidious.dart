import 'package:spotube/services/youtube_engine/invidious_engine.dart';
void main() async {
  final engine = InvidiousEngine();
  try {
    final results = await engine.searchVideos('Never gonna give you up');
    print('Found ${results.length} results');
    if (results.isNotEmpty) {
      print('First result channel id: ${results.first.channelId.value}');
    }
  } catch (e, stack) {
    print('Failed with $e');
    print(stack);
  } finally {
    engine.dispose();
  }
}
