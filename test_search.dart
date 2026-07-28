import 'package:dio/dio.dart';

void main() async {
  final dio = Dio();
  const url = 'https://inv.thepixora.com/api/v1/search';
  try {
    final res =
        await dio.get(url, queryParameters: {'q': 'bluff', 'type': 'video'});
    if (res.data is List) {
      print("Search returned \${(res.data as List).length} results");
      if ((res.data as List).isNotEmpty) {
        print("First result: \${res.data[0]}");
      }
    } else {
      print("Search returned non-list: \${res.data}");
    }
  } catch (e) {
    if (e is DioException) {
      print("Search error -> \${e.response?.statusCode} \${e.message}");
    } else {
      print("Error: \$e");
    }
  }
}
