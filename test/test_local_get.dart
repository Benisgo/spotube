import 'package:dio/dio.dart';

void main() async {
  final dio = Dio();
  
  final invUrl = 'https://inv.thepixora.com/latest_version?id=sELM9aIKHiw&itag=251&local=true';
  print('Testing GET $invUrl');
  
  try {
    final res = await dio.get(invUrl, options: Options(
      validateStatus: (_) => true,
      followRedirects: true,
      responseType: ResponseType.stream,
      headers: {
        "user-agent": "Mozilla/5.0 (Linux; Android 14)",
      }
    ));
    print('Final status: ${res.statusCode}');
    
    num count = 0;
    await for (final chunk in res.data!.stream) {
      count += chunk.length;
    }
    print('Total bytes: $count');
  } catch (e, s) {
    print('Error: $e');
    print(s);
  }
}
