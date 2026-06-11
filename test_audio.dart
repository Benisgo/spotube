import 'package:dio/dio.dart';

void main() async {
  final dio = Dio();
  final url = 'https://inv.thepixora.com/api/v1/videos/xHccqC3_K20';
  try {
    final res = await dio.get(url);
    if (res.data is Map) {
      final formats = res.data['adaptiveFormats'] as List<dynamic>?;
      print("Got " + (formats?.length.toString() ?? "0") + " adaptive formats.");
      if (formats != null && formats.isNotEmpty) {
        final audioOnly = formats.where((f) => (f['type'] as String?)?.startsWith('audio/') == true).toList();
        print("Audio formats: " + audioOnly.length.toString());
      }
    }
  } catch (e) {
    if (e is DioException) {
      print("Error -> " + (e.response?.statusCode.toString() ?? "null") + " " + (e.message ?? ""));
    } else {
      print("Error: " + e.toString());
    }
  }
}
