import 'package:dio/dio.dart';
import 'package:spotube/services/youtube_engine/verome_engine.dart';
import 'package:spotube/services/youtube_engine/invidious_engine.dart';

void main() async {
  final dio = Dio();
  
  Future<void> testEngine(String name, dynamic engine) async {
    print('Testing $name...');
    try {
      final results = await engine.searchVideos('Never gonna give you up');
      if (results.isEmpty) {
        print('$name: No results');
        return;
      }
      final video = results.first;
      final manifest = await engine.getStreamManifest(video.id.value);
      final streams = manifest.audioOnly;
      if (streams.isEmpty) {
        print('$name: No streams');
        return;
      }
      print('$name: Found ${streams.length} streams');
      
      for (var stream in streams) {
        try {
          final res = await dio.head(
            stream.url.toString(),
            options: Options(
              headers: {
                "user-agent": "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.6367.83 Mobile Safari/537.36",
                "referer": "https://www.youtube.com/",
              },
              validateStatus: (status) => status != null && status < 500,
            ),
          );
          print('  Stream ${stream.bitrate}: ${res.statusCode}');
        } catch (e) {
          print('  Stream ${stream.bitrate}: Network Error $e');
        }
      }
    } catch (e, s) {
      print('$name: Error $e\n$s');
    }
  }

  final verome = VeromeEngine();
  final invidious = InvidiousEngine();
  
  await testEngine('Verome', verome);
  await testEngine('Invidious', invidious);
  
  verome.dispose();
  invidious.dispose();
}
