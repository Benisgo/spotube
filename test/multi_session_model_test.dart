import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/models/multi_session/multi_session.dart';
import 'package:spotube/provider/multi_session/multi_session.dart';

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
      MultiSessionNotifier.normalizeRelayUrl('relay.example.com'),
      'https://relay.example.com',
    );
    expect(
      MultiSessionNotifier.normalizeRelayUrl('wss://relay.example.com/ws'),
      'https://relay.example.com/ws',
    );
    expect(
      MultiSessionNotifier.normalizeRelayUrl('localhost:8787'),
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
}
