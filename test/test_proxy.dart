import 'package:dio/dio.dart';
import 'package:spotube/services/youtube_engine/verome_engine.dart';
import 'package:spotube/services/youtube_engine/invidious_engine.dart';

void main() async {
  final verome = VeromeEngine();
  final dio = Dio();
  try {
    print('Searching Verome...');
    final results = await verome.searchVideos('Never gonna give you up');
    final streams = await verome.getStreamManifest(results.first.id.value);
    final url = streams.audioOnly.first.url;
    print('Verome URL: $url');
    
    final options = Options(
      headers: {
        "user-agent": "mpv 0.35.0",
        "referer": "https://www.youtube.com/",
        "host": url.host,
        "range": "bytes=0-1024",
      },
      responseType: ResponseType.stream,
      validateStatus: (_) => true,
    );
    
    final res = await dio.get<ResponseBody>(url.toString(), options: options);
    print('Verome GET status: ${res.statusCode}');
    print('Verome GET headers: ${res.headers.map}');
    if (res.statusCode != 200 && res.statusCode != 206) {
      print('Verome failed!');
    }
  } catch (e, s) {
    print('Error: $e\n$s');
  } finally {
    verome.dispose();
  }
}
