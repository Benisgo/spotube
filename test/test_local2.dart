import 'package:dio/dio.dart';

void main() async {
  final dio = Dio();
  
  const invUrl = 'https://inv.thepixora.com/latest_version?id=sELM9aIKHiw&itag=251&local=true';
  print('Testing $invUrl');
  
  try {
    final res = await dio.head(invUrl, options: Options(
      validateStatus: (_) => true,
      followRedirects: true, // Follow redirects this time!
      headers: {
        "user-agent": "Mozilla/5.0 (Linux; Android 14)",
      }
    ));
    print('Final status: ${res.statusCode}');
    print('Final URI: ${res.realUri}');
    print('Headers: ${res.headers}');
  } catch (e) {
    print('Error: $e');
  }
}
