import 'package:dio/dio.dart';

void main() async {
  final dio = Dio();
  final url = 'https://inv.thepixora.com/latest_version?id=sELM9aIKHiw&itag=251&local=true';
  try {
    final res = await dio.head(
      url,
      options: Options(
        headers: {
          "user-agent": "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.6367.83 Mobile Safari/537.36",
          "referer": "https://www.youtube.com/",
        },
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    print("HEAD \$url -> \${res.statusCode}");
  } catch (e) {
    if (e is DioException) {
      print("HEAD error -> \${e.response?.statusCode} \${e.message}");
    } else {
      print("Error: \$e");
    }
  }
}
