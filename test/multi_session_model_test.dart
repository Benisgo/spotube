import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/models/multi_session/multi_session.dart';

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
}
