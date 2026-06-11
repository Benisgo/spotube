import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

void main() async {
  final handler = const Pipeline().addHandler((request) {
    try {
      return Response(
        200,
        body: "hello world",
        headers: {
          'content-type': ['text/plain'],
          'x-custom': ['value1', 'value2']
        },
      );
    } catch (e) {
      print('Error creating response: $e');
      return Response.internalServerError();
    }
  });
  final server = await io.serve(handler, 'localhost', 0);
  print('Server running on port ${server.port}');
  
  final client = HttpClient();
  final req = await client.getUrl(Uri.parse('http://localhost:${server.port}/'));
  final res = await req.close();
  print('Status: ${res.statusCode}');
  print('Headers: ${res.headers}');
  
  server.close();
}
