import 'package:dio/dio.dart';
import 'package:spotube/services/youtube_engine/invidious_engine.dart';

void main() async {
  final dio = Dio();
  final invidious = InvidiousEngine();

  try {
    final results = await invidious.searchVideos('bluff by akio');
    if (results.isEmpty) return;

    final video = results.first;
    final manifest = await invidious.getStreamManifest(video.id.value);
    final streams = manifest.audioOnly;

    for (var stream in streams) {
      final url = stream.url.toString();
      print('URL: $url');

      final res = await dio.head(url,
          options: Options(
            headers: {
              "user-agent":
                  "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.6367.83 Mobile Safari/537.36",
              "referer": "https://www.youtube.com/",
            },
            validateStatus: (_) => true,
          ));
      print('Status: ${res.statusCode}');
      if (res.statusCode == 403) {
        print('Headers: ${res.headers}');
      }
    }
  } catch (e, s) {
    print('Error: $e\n$s');
  }
}
