import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/services/metadata/endpoints/normalize.dart';

void main() {
  group('normalizeTrackMap', () {
    test('passes flat camelCase through unchanged', () {
      final map = normalizeTrackMap({
        'id': 'abc',
        'name': 'Song',
        'durationMs': 180000,
        'addedAt': '2024-01-01T00:00:00Z',
        'album': {'name': 'Album', 'releaseDate': '2024'},
      });
      expect(map['durationMs'], 180000);
      expect(map['addedAt'], '2024-01-01T00:00:00Z');
      expect((map['album'] as Map)['releaseDate'], '2024');
    });

    test('maps snake_case REST fields to camelCase', () {
      final map = normalizeTrackMap({
        'id': 'abc',
        'name': 'Song',
        'duration_ms': 180000,
        'added_at': '2024-01-01T00:00:00Z',
        'album': {'name': 'Album', 'release_date': '2024-05-01'},
      });
      expect(map['durationMs'], 180000);
      expect(map['addedAt'], '2024-01-01T00:00:00Z');
      expect((map['album'] as Map)['releaseDate'], '2024-05-01');
    });

    test('unwraps {added_at, track} wrapper and carries addedAt', () {
      final map = normalizeTrackMap({
        'added_at': '2023-06-15T10:00:00Z',
        'track': {
          'id': 'xyz',
          'name': 'Wrapped',
          'duration_ms': 200000,
          'album': {'name': 'A', 'release_date': '2020'},
        },
      });
      expect(map['id'], 'xyz');
      expect(map['name'], 'Wrapped');
      expect(map['durationMs'], 200000);
      expect(map['addedAt'], '2023-06-15T10:00:00Z');
      expect((map['album'] as Map)['releaseDate'], '2020');
    });
  });
}
