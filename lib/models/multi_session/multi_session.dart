import 'dart:convert';

import 'package:collection/collection.dart';

enum MultiSessionPermission {
  controlPlayback,
  editQueue,
  invite,
  manageMembers;
}

class MultiSessionMember {
  final String id;
  final String name;
  final String role;
  final Map<MultiSessionPermission, bool> permissions;

  const MultiSessionMember({
    required this.id,
    required this.name,
    required this.role,
    required this.permissions,
  });

  factory MultiSessionMember.fromJson(Map<String, dynamic> json) {
    return MultiSessionMember(
      id: json["id"] as String,
      name: json["name"] as String,
      role: json["role"] as String,
      permissions: {
        for (final permission in MultiSessionPermission.values)
          permission: (json["permissions"] as Map?)?[permission.name] == true,
      },
    );
  }
}

class MultiSessionRoomSnapshot {
  final String roomId;
  final String code;
  final int sequence;
  final List<Map<String, dynamic>> queue;
  final String? activeTrackId;
  final int positionMs;
  final bool playing;
  final List<MultiSessionMember> members;

  const MultiSessionRoomSnapshot({
    required this.roomId,
    required this.code,
    required this.sequence,
    required this.queue,
    required this.activeTrackId,
    required this.positionMs,
    required this.playing,
    required this.members,
  });

  factory MultiSessionRoomSnapshot.fromJson(Map<String, dynamic> json) {
    return MultiSessionRoomSnapshot(
      roomId: json["roomId"] as String,
      code: json["code"] as String,
      sequence: json["sequence"] as int,
      queue: (json["queue"] as List? ?? [])
          .cast<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList(),
      activeTrackId: json["activeTrackId"] as String?,
      positionMs: json["positionMs"] as int? ?? 0,
      playing: json["playing"] == true,
      members: (json["members"] as List? ?? [])
          .cast<Map>()
          .map((item) => MultiSessionMember.fromJson(item.cast<String, dynamic>()))
          .toList(),
    );
  }
}

class MultiSessionState {
  final String? roomId;
  final String? code;
  final String? token;
  final String? memberId;
  final MultiSessionRoomSnapshot? snapshot;
  final bool connected;
  final bool connecting;
  final String? error;

  const MultiSessionState({
    this.roomId,
    this.code,
    this.token,
    this.memberId,
    this.snapshot,
    this.connected = false,
    this.connecting = false,
    this.error,
  });

  MultiSessionMember? get currentMember {
    if (memberId == null || snapshot == null) return null;
    return snapshot!.members.where((member) => member.id == memberId).firstOrNull;
  }

  bool get isHost => currentMember?.role == "host";

  bool can(MultiSessionPermission permission) {
    return isHost || currentMember?.permissions[permission] == true;
  }

  MultiSessionState copyWith({
    String? roomId,
    String? code,
    String? token,
    String? memberId,
    MultiSessionRoomSnapshot? snapshot,
    bool? connected,
    bool? connecting,
    String? error,
    bool clearRoom = false,
    bool clearError = false,
  }) {
    if (clearRoom) return const MultiSessionState();
    return MultiSessionState(
      roomId: roomId ?? this.roomId,
      code: code ?? this.code,
      token: token ?? this.token,
      memberId: memberId ?? this.memberId,
      snapshot: snapshot ?? this.snapshot,
      connected: connected ?? this.connected,
      connecting: connecting ?? this.connecting,
      error: clearError ? null : error ?? this.error,
    );
  }
}

String encodeRoomEvent(String type, Object? data) {
  return jsonEncode({"type": type, "data": data});
}
