import 'package:dio/dio.dart';

void main() async {
  final dio = Dio();

  // Track 1: '0bnSXl0lY92annYcbgo1T2' (What is this song?)
  // Let's test a known potentially age-restricted or problematic song.
  // Or maybe we can just query the verome api to search for something that might be age restricted.
  // Wait, I can use SpotifyApi to get the track name!

  // Let's just do a GET request to the Spotify API using public unauthenticated endpoint if possible,
  // or scrape the spotify web page.
  final res1 =
      await dio.get('https://open.spotify.com/track/0bnSXl0lY92annYcbgo1T2');
  final title1 =
      RegExp(r'<title>(.*?) - song and lyrics by (.*?) \| Spotify</title>')
          .firstMatch(res1.data.toString());
  print('Track 1: ${title1?.group(1)} by ${title1?.group(2)}');

  final res2 =
      await dio.get('https://open.spotify.com/track/6FNYucvtKe0Qt6b23dYqHL');
  final title2 =
      RegExp(r'<title>(.*?) - song and lyrics by (.*?) \| Spotify</title>')
          .firstMatch(res2.data.toString());
  print('Track 2: ${title2?.group(1)} by ${title2?.group(2)}');
}
