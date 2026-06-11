import 'package:dio/dio.dart';
import 'package:spotube/services/youtube_engine/invidious_engine.dart';
import 'package:spotube/services/youtube_engine/verome_engine.dart';

void main() async {
  final invidious = InvidiousEngine();
  final verome = VeromeEngine();
  final dio = Dio();
  
  try {
    print('--- Testing Invidious ---');
    final invResults = await invidious.searchVideos('Never gonna give you up');
    final invStreams = await invidious.getStreamManifest(invResults.first.id.value);
    final invUrl = invStreams.audioOnly.first.url;
    print('Invidious Stream URL: $invUrl');
    
    final invRes = await dio.headUri(invUrl, options: Options(validateStatus: (_) => true));
    print('Invidious Stream HEAD Status: ${invRes.statusCode}');
    
    print('\n--- Testing Verome ---');
    final verResults = await verome.searchVideos('Never gonna give you up');
    final verStreams = await verome.getStreamManifest(verResults.first.id.value);
    final verUrl = verStreams.audioOnly.first.url;
    print('Verome Stream URL: $verUrl');
    
    final verRes = await dio.headUri(verUrl, options: Options(validateStatus: (_) => true));
    print('Verome Stream HEAD Status: ${verRes.statusCode}');
    
  } catch (e, stack) {
    print('Failed: $e\n$stack');
  } finally {
    invidious.dispose();
    verome.dispose();
    dio.close();
  }
}
