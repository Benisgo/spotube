import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/services/sourced_track/sourced_track.dart';

void main() {
  SpotubeFullTrackObject track({
    required String id,
    required String name,
    required List<SpotubeSimpleArtistObject> artists,
    required Duration duration,
  }) =>
      SpotubeTrackObject.full(
        id: id,
        name: name,
        externalUri: 'spotify:track:$id',
        artists: artists,
        album: SpotubeSimpleAlbumObject(
          id: 'album-$id',
          name: 'Album',
          externalUri: 'spotify:album:$id',
          artists: artists,
          images: const [],
          albumType: SpotubeAlbumType.single,
          releaseDate: '2020-01-01',
        ),
        durationMs: duration.inMilliseconds,
        isrc: 'US1234567890',
        explicit: false,
      ) as SpotubeFullTrackObject;

  SpotubeSimpleArtistObject artist(String name) => SpotubeSimpleArtistObject(
        id: name.toLowerCase().replaceAll(' ', '-'),
        name: name,
        externalUri: 'spotify:artist:${name.hashCode}',
      );

  SpotubeAudioSourceMatchObject candidate({
    required String id,
    required String title,
    required List<String> artists,
    required Duration duration,
  }) =>
      SpotubeAudioSourceMatchObject(
        id: id,
        title: title,
        artists: artists,
        duration: duration,
        externalUri: 'https://youtube.com/watch?v=$id',
      );

  test('experimental scoring rewards the exact-duration match', () {
    final queen = artist('Queen');
    final target = track(
      id: 'bohemian',
      name: 'Bohemian Rhapsody',
      artists: [queen],
      duration: const Duration(minutes: 5, seconds: 55),
    );

    final ranked = SourcedTrack.rankResultsExperimental([
      candidate(
        id: 'long-version',
        title: 'Bohemian Rhapsody',
        artists: const ['Queen'],
        duration: const Duration(minutes: 6, seconds: 35),
      ),
      candidate(
        id: 'exact-duration',
        title: 'Bohemian Rhapsody',
        artists: const ['Queen'],
        duration: const Duration(minutes: 5, seconds: 55),
      ),
    ], target);

    // Same title/artist signals; only the >=30s duration delta differs.
    expect(ranked.first.id, 'exact-duration');
  });

  test('experimental scoring penalizes a missing artist match', () {
    final sheeran = artist('Ed Sheeran');
    final target = track(
      id: 'shape',
      name: 'Shape of You',
      artists: [sheeran],
      duration: const Duration(minutes: 3, seconds: 53),
    );

    final ranked = SourcedTrack.rankResultsExperimental([
      candidate(
        id: 'wrong-artist',
        title: 'Shape of You',
        artists: const ['Random Cover Band'],
        duration: const Duration(minutes: 3, seconds: 53),
      ),
      candidate(
        id: 'right-artist',
        title: 'Shape of You',
        artists: const ['Ed Sheeran'],
        duration: const Duration(minutes: 3, seconds: 53),
      ),
    ], target);

    // Identical titles/durations; the -45 no-artist-match penalty decides it.
    expect(ranked.first.id, 'right-artist');
  });

  test('experimental scoring prefers official audio over the music video', () {
    final weeknd = artist('The Weeknd');
    final target = track(
      id: 'blinding',
      name: 'Blinding Lights',
      artists: [weeknd],
      duration: const Duration(minutes: 3, seconds: 20),
    );

    final ranked = SourcedTrack.rankResultsExperimental([
      candidate(
        id: 'music-video',
        title: 'Blinding Lights (Official Music Video)',
        artists: const ['The Weeknd'],
        duration: const Duration(minutes: 3, seconds: 20),
      ),
      candidate(
        id: 'official-audio',
        title: 'Blinding Lights (Official Audio)',
        artists: const ['The Weeknd - Topic'],
        duration: const Duration(minutes: 3, seconds: 20),
      ),
    ], target);

    // Official audio gets +14, +16 Topic bonus and no music-video penalty.
    expect(ranked.first.id, 'official-audio');
  });

  test('experimental scoring is stable for equal scores (original order)', () {
    final target = track(
      id: 'tie',
      name: 'Tie Track',
      artists: [artist('Artist')],
      duration: const Duration(minutes: 3, seconds: 0),
    );

    final a = candidate(
      id: 'first',
      title: 'Tie Track',
      artists: const ['Artist'],
      duration: const Duration(minutes: 3, seconds: 0),
    );
    final b = candidate(
      id: 'second',
      title: 'Tie Track',
      artists: const ['Artist'],
      duration: const Duration(minutes: 3, seconds: 0),
    );

    final ranked = SourcedTrack.rankResultsExperimental([a, b], target);

    expect(ranked.map((r) => r.id), ['first', 'second']);
  });
}
