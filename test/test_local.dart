import 'package:dio/dio.dart';
import 'package:spotube/services/youtube_engine/verome_engine.dart';
import 'package:spotube/services/youtube_engine/invidious_engine.dart';

void main() async {
  final dio = Dio();
  final invidious = InvidiousEngine();
  
  try {
    final results = await invidious.searchVideos('bluff by akio');
    final video = results.first;
    print('Video ID: ${video.id.value}');
    
    // Test Invidious proxy URL
    final invUrl = 'https://inv.thepixora.com/latest_version?id=${video.id.value}&itag=251&local=true';
    print('Testing $invUrl');
    
    final res = await dio.head(invUrl, options: Options(
      validateStatus: (_) => true,
      followRedirects: false, // Don't follow redirects to see if it actually proxies
    ));
    print('Invidious local=true status: ${res.statusCode}');
    if (res.statusCode == 302) {
       print('It redirected to: ${res.headers.value('location')}');
    }
    
    // What about Verome?
    final verUrl = 'https://yt.omada.cafe/latest_version?id=${video.id.value}&itag=251&local=true';
    print('Testing $verUrl');
    final res2 = await dio.head(verUrl, options: Options(
      validateStatus: (_) => true,
      followRedirects: false,
    ));
    print('Verome local=true status: ${res2.statusCode}');
    if (res2.statusCode == 302) {
       print('It redirected to: ${res2.headers.value('location')}');
    }
  } catch (e, s) {
    print('Error: $e');
  }
}
