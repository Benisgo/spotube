import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/collections/spotube_icons.dart';

void main() {
  test('spotube icons are available', () {
    expect(SpotubeIcons.add, isNotNull);
    expect(SpotubeIcons.play, isNotNull);
  });
}
