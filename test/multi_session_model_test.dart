import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/models/multi_session/multi_session.dart';
import 'package:spotube/provider/multi_session/multi_session.dart';
import 'package:spotube/services/sourced_track/sourced_track.dart';

void main() {
  test('parses multi-session invite uri', () {
    final invite = parseMultiSessionInviteUri(
      'spotube://multi-session/join?code=ABC123&relay=https%3A%2F%2Frelay.example.com',
    );

    expect(invite, isNotNull);
    expect(invite!.code, 'ABC123');
    expect(invite.relayUrl, 'https://relay.example.com');
  });

  test('snapshot remains backward compatible when new fields are missing', () {
    final snapshot = MultiSessionRoomSnapshot.fromJson({
      'roomId': 'room-1',
      'code': 'ABC123',
      'sequence': 1,
      'queue': const [],
      'activeTrackId': null,
      'positionMs': 0,
      'playing': false,
      'members': const [],
    });

    expect(snapshot.communityQueueEnabled, isTrue);
    expect(snapshot.suggestions, isEmpty);
  });

  test('explicit member permissions override preset defaults', () {
    final member = MultiSessionMember.fromJson({
      'id': 'member-1',
      'name': 'Listener',
      'role': 'member',
      'preset': 'dj',
      'permissions': {
        'controlPlayback': false,
        'suggestTracks': true,
      },
    });

    expect(
      member.permissions[MultiSessionPermission.controlPlayback],
      isFalse,
    );
    expect(member.permissions[MultiSessionPermission.suggestTracks], isTrue);
  });

  test('member images parse from relay avatar fields', () {
    final member = MultiSessionMember.fromJson({
      'id': 'member-1',
      'name': 'Listener',
      'role': 'member',
      'preset': 'listener',
      'images': const [
        {'url': ''},
      ],
      'avatarUrl': 'https://i.scdn.co/image/avatar-a',
      'photoUrl': 'https://i.scdn.co/image/avatar-b',
    });

    expect(member.images, isNotEmpty);
    expect(member.images.first.url, 'https://i.scdn.co/image/avatar-a');
  });

  test('normalizes relay urls before validation', () {
    expect(
      normalizeRelayUrl('relay.example.com'),
      'https://relay.example.com',
    );
    expect(
      normalizeRelayUrl('wss://relay.example.com/ws'),
      'https://relay.example.com/ws',
    );
    expect(
      normalizeRelayUrl('localhost:8787'),
      'http://localhost:8787',
    );
  });

  test('playlist metadata tolerates null string fields', () {
    final playlist = SpotubeSimplePlaylistObject.fromJson({
      'id': 'playlist-1',
      'name': 'My Playlist',
      'description': null,
      'externalUri': null,
      'owner': {
        'id': 'user-1',
        'name': null,
        'externalUri': null,
      },
      'images': const [],
    });

    expect(playlist.description, '');
    expect(playlist.externalUri, '');
    expect(playlist.owner.name, '');
    expect(playlist.owner.externalUri, '');
  });

  test('experimental scoring prefers music-only matches over music videos', () {
    final SpotubeFullTrackObject track = SpotubeTrackObject.full(
      id: 'track-1',
      name: 'Let It Go',
      externalUri: 'spotify:track:1',
      artists: [
        SpotubeSimpleArtistObject(
          id: 'artist-1',
          name: 'Idina Menzel',
          externalUri: 'spotify:artist:1',
        ),
      ],
      album: SpotubeSimpleAlbumObject(
        id: 'album-1',
        name: 'Frozen',
        externalUri: 'spotify:album:1',
        artists: [
          SpotubeSimpleArtistObject(
            id: 'artist-1',
            name: 'Idina Menzel',
            externalUri: 'spotify:artist:1',
          ),
        ],
        images: const [],
        albumType: SpotubeAlbumType.album,
        releaseDate: '2013-01-01',
      ),
      durationMs: 225000,
      isrc: 'US1234567890',
      explicit: false,
    ) as SpotubeFullTrackObject;

    final ranked = SourcedTrack.rankResultsExperimental([
      SpotubeAudioSourceMatchObject(
        id: 'video',
        title: 'Let It Go (Official Music Video)',
        artists: const ['DisneyMusicVEVO'],
        duration: const Duration(minutes: 4, seconds: 3),
        externalUri: 'https://youtube.com/watch?v=video',
      ),
      SpotubeAudioSourceMatchObject(
        id: 'audio',
        title: 'Let It Go',
        artists: const ['Idina Menzel - Topic'],
        duration: const Duration(minutes: 3, seconds: 45),
        externalUri: 'https://youtube.com/watch?v=audio',
      ),
    ], track);

    expect(ranked.first.id, 'audio');
  });

  test('experimental scoring prefers matching artist over lyric reuploads', () {
    final SpotubeFullTrackObject track = SpotubeTrackObject.full(
      id: 'track-2',
      name: "everything i'm not",
      externalUri: 'spotify:track:2',
      artists: [
        SpotubeSimpleArtistObject(
          id: 'artist-2',
          name: 'Brooke Wheeler',
          externalUri: 'spotify:artist:2',
        ),
      ],
      album: SpotubeSimpleAlbumObject(
        id: 'album-2',
        name: "everything i'm not",
        externalUri: 'spotify:album:2',
        artists: [
          SpotubeSimpleArtistObject(
            id: 'artist-2',
            name: 'Brooke Wheeler',
            externalUri: 'spotify:artist:2',
          ),
        ],
        images: const [],
        albumType: SpotubeAlbumType.single,
        releaseDate: '2024-01-01',
      ),
      durationMs: 195000,
      isrc: 'US1234567891',
      explicit: false,
    ) as SpotubeFullTrackObject;

    final ranked = SourcedTrack.rankResultsExperimental([
      SpotubeAudioSourceMatchObject(
        id: 'lyrics-reupload',
        title: "Brooke Daye - Everything I'm not (Lyrics)",
        artists: const ['Loku'],
        duration: const Duration(minutes: 3, seconds: 15),
        externalUri: 'https://youtube.com/watch?v=lyrics',
      ),
      SpotubeAudioSourceMatchObject(
        id: 'official-track',
        title: "everything i'm not",
        artists: const ['Brooke Wheeler'],
        duration: const Duration(minutes: 3, seconds: 15),
        externalUri: 'https://youtube.com/watch?v=official',
      ),
    ], track);

    expect(ranked.first.id, 'official-track');
  });
}
