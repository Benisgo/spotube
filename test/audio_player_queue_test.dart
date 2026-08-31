import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/services/audio_player/audio_player.dart';

void main() {
  SpotubeFullTrackObject fullTrack({
    required String id,
    String name = 'Test Track',
  }) =>
      SpotubeTrackObject.full(
        id: id,
        name: name,
        externalUri: 'spotify:track:$id',
        artists: [
          SpotubeSimpleArtistObject(
            id: 'artist-$id',
            name: 'Artist $id',
            externalUri: 'spotify:artist:$id',
          ),
        ],
        album: SpotubeSimpleAlbumObject(
          id: 'album-$id',
          name: 'Album $id',
          externalUri: 'spotify:album:$id',
          artists: [
            SpotubeSimpleArtistObject(
              id: 'artist-$id',
              name: 'Artist $id',
              externalUri: 'spotify:artist:$id',
            ),
          ],
          images: const [],
          albumType: SpotubeAlbumType.album,
          releaseDate: '2020-01-01',
        ),
        durationMs: 180000,
        isrc: 'US1234567890',
        explicit: false,
      ) as SpotubeFullTrackObject;

  SpotubeLocalTrackObject localTrack(String path) => SpotubeTrackObject.local(
        id: 'local-id-$path',
        name: 'Local Track',
        externalUri: 'file://$path',
        artists: const [],
        album: SpotubeSimpleAlbumObject(
          id: 'album-local',
          name: 'Local Album',
          externalUri: 'file://album',
          artists: const [],
          images: const [],
          albumType: SpotubeAlbumType.album,
          releaseDate: '2020-01-01',
        ),
        durationMs: 100000,
        path: path,
      ) as SpotubeLocalTrackObject;

  group('trackQueueKey', () {
    test('remote tracks are keyed by id', () {
      expect(trackQueueKey(fullTrack(id: 'abc')), 'abc');
    });

    test('local tracks are keyed by path with a local: prefix', () {
      expect(
        trackQueueKey(localTrack('/music/a.mp3')),
        'local:/music/a.mp3',
      );
    });

    test('two local tracks with the same path share a key', () {
      expect(
        trackQueueKey(localTrack('/music/a.mp3')),
        trackQueueKey(localTrack('/music/a.mp3')),
      );
    });

    test('local and remote keys never collide for the same id', () {
      expect(
        trackQueueKey(localTrack('/music/x.mp3')),
        isNot(trackQueueKey(fullTrack(id: 'x'))),
      );
    });
  });

  group('deduplicateQueueTracks', () {
    test('filters tracks whose key is already present in existingKeys', () {
      final existing = fullTrack(id: 'a');
      final result = deduplicateQueueTracks(
        [existing, fullTrack(id: 'a'), fullTrack(id: 'b')],
        {trackQueueKey(existing)},
      );

      expect(result.map((t) => t.id), ['b']);
    });

    test('allowDuplicates keeps every track including repeats', () {
      final tracks = [fullTrack(id: 'a'), fullTrack(id: 'a')];
      final result = deduplicateQueueTracks(
        tracks,
        {trackQueueKey(fullTrack(id: 'a'))},
        allowDuplicates: true,
      );

      expect(result.length, 2);
    });

    test('dedupes local tracks by path', () {
      final local = localTrack('/music/a.mp3');
      final result = deduplicateQueueTracks(
        [local, localTrack('/music/a.mp3'), localTrack('/music/b.mp3')],
        {trackQueueKey(local)},
      );

      expect(
        result.map((t) => (t as SpotubeLocalTrackObject).path),
        ['/music/b.mp3'],
      );
    });

    test('empty existingKeys keeps all tracks', () {
      final tracks = [fullTrack(id: 'a'), fullTrack(id: 'b')];
      final result = deduplicateQueueTracks(tracks, {});

      expect(result.length, 2);
    });
  });

  group('descendingTrackIndexes', () {
    test('returns original positions in descending order', () {
      final tracks = [
        fullTrack(id: 'a'),
        fullTrack(id: 'b'),
        fullTrack(id: 'c'),
        fullTrack(id: 'd'),
      ];

      // Removing {a, d} from the player must use indexes [3, 0] (highest
      // first), not the filtered-copy positions [1, 0] that would remove the
      // wrong tracks once indexes shift.
      expect(descendingTrackIndexes(tracks, {'a', 'd'}), [3, 0]);
    });

    test('handles contiguous removals without index shifting errors', () {
      final tracks = [
        fullTrack(id: 'a'),
        fullTrack(id: 'b'),
        fullTrack(id: 'c'),
      ];

      expect(descendingTrackIndexes(tracks, {'a', 'b', 'c'}), [2, 1, 0]);
    });

    test('no ids to remove returns an empty list', () {
      final tracks = [fullTrack(id: 'a'), fullTrack(id: 'b')];

      expect(descendingTrackIndexes(tracks, {}), isEmpty);
    });

    test('unknown ids are ignored', () {
      final tracks = [fullTrack(id: 'a'), fullTrack(id: 'b')];

      expect(descendingTrackIndexes(tracks, {'zzz'}), isEmpty);
    });
  });

  group('playlistContentSignature', () {
    test('is deterministic for identical content', () {
      String build() => playlistContentSignature(
            length: 3,
            index: 0,
            uris: const ['u1', 'u2', 'u3'],
          );

      expect(build(), build());
    });

    test('changes when track order changes', () {
      final a = playlistContentSignature(
        length: 3,
        index: 0,
        uris: const ['u1', 'u2', 'u3'],
      );
      final b = playlistContentSignature(
        length: 3,
        index: 0,
        uris: const ['u1', 'u3', 'u2'],
      );

      expect(a, isNot(b));
    });

    test('changes when the playing index changes', () {
      final a = playlistContentSignature(
        length: 2,
        index: 0,
        uris: const ['u1', 'u2'],
      );
      final b = playlistContentSignature(
        length: 2,
        index: 1,
        uris: const ['u1', 'u2'],
      );

      expect(a, isNot(b));
    });

    test('changes when a track is appended', () {
      final a = playlistContentSignature(
        length: 2,
        index: 0,
        uris: const ['u1', 'u2'],
      );
      final b = playlistContentSignature(
        length: 3,
        index: 0,
        uris: const ['u1', 'u2', 'u3'],
      );

      expect(a, isNot(b));
    });

    test('empty playlist produces a stable signature', () {
      expect(
        playlistContentSignature(length: 0, index: 0, uris: const []),
        playlistContentSignature(length: 0, index: 0, uris: const []),
      );
    });
  });
}
