import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:spotube/models/metadata/metadata.dart';

enum MultiSessionPermission {
  controlPlayback,
  editQueue,
  invite,
  manageMembers,
  suggestTracks,
  voteTracks;
}

enum MultiSessionMemberPreset {
  listener("Listener"),
  dj("DJ"),
  coHost("Co-host"),
  custom("Custom");

  final String label;

  const MultiSessionMemberPreset(this.label);

  static MultiSessionMemberPreset fromName(String? name) {
    return MultiSessionMemberPreset.values.firstWhere(
      (preset) => preset.name == name,
      orElse: () => MultiSessionMemberPreset.custom,
    );
  }
}

class MultiSessionUiNotice {
  final String message;
  final bool destructive;
  final int id;

  const MultiSessionUiNotice({
    required this.message,
    this.destructive = false,
    required this.id,
  });
}

Map<MultiSessionPermission, bool> multiSessionPresetPermissions(
  MultiSessionMemberPreset preset,
) {
  switch (preset) {
    case MultiSessionMemberPreset.listener:
      return const {
        MultiSessionPermission.controlPlayback: false,
        MultiSessionPermission.editQueue: false,
        MultiSessionPermission.invite: false,
        MultiSessionPermission.manageMembers: false,
        MultiSessionPermission.suggestTracks: true,
        MultiSessionPermission.voteTracks: true,
      };
    case MultiSessionMemberPreset.dj:
      return const {
        MultiSessionPermission.controlPlayback: true,
        MultiSessionPermission.editQueue: false,
        MultiSessionPermission.invite: false,
        MultiSessionPermission.manageMembers: false,
        MultiSessionPermission.suggestTracks: true,
        MultiSessionPermission.voteTracks: true,
      };
    case MultiSessionMemberPreset.coHost:
      return const {
        MultiSessionPermission.controlPlayback: true,
        MultiSessionPermission.editQueue: true,
        MultiSessionPermission.invite: true,
        MultiSessionPermission.manageMembers: true,
        MultiSessionPermission.suggestTracks: true,
        MultiSessionPermission.voteTracks: true,
      };
    case MultiSessionMemberPreset.custom:
      return const {
        MultiSessionPermission.controlPlayback: false,
        MultiSessionPermission.editQueue: false,
        MultiSessionPermission.invite: false,
        MultiSessionPermission.manageMembers: false,
        MultiSessionPermission.suggestTracks: false,
        MultiSessionPermission.voteTracks: false,
      };
  }
}

class MultiSessionMember {
  final String id;
  final String name;
  final String role;
  final MultiSessionMemberPreset preset;
  final Map<MultiSessionPermission, bool> permissions;
  final List<SpotubeImageObject> images;

  const MultiSessionMember({
    required this.id,
    required this.name,
    required this.role,
    required this.preset,
    required this.permissions,
    required this.images,
  });

  static List<SpotubeImageObject> _parseImages(Map<String, dynamic> json) {
    final results = <SpotubeImageObject>[];

    void addUrl(String? value) {
      final url = value?.trim();
      if (url == null || url.isEmpty) return;
      if (results.any((image) => image.url == url)) return;
      results.add(SpotubeImageObject(url: url));
    }

    final rawImages = json["images"];
    if (rawImages is List) {
      for (final item in rawImages) {
        if (item is String) {
          addUrl(item);
          continue;
        }

        if (item is Map) {
          final mapped = item.cast<Object?, Object?>();
          final url = mapped["url"]?.toString().trim();
          if (url == null || url.isEmpty) continue;

          final width = int.tryParse((mapped["width"] ?? "").toString());
          final height = int.tryParse((mapped["height"] ?? "").toString());
          if (results.any((image) => image.url == url)) continue;

          results.add(
            SpotubeImageObject(
              url: url,
              width: width,
              height: height,
            ),
          );
        }
      }
    }

    addUrl(json["imageUrl"]?.toString());
    addUrl(json["avatarUrl"]?.toString());
    addUrl(json["photoUrl"]?.toString());

    return results;
  }

  factory MultiSessionMember.fromJson(Map<String, dynamic> json) {
    final preset = json["role"] == "host"
        ? MultiSessionMemberPreset.coHost
        : MultiSessionMemberPreset.fromName(json["preset"] as String?);

    final defaults = json["role"] == "host"
        ? {
            for (final permission in MultiSessionPermission.values)
              permission: true,
          }
        : multiSessionPresetPermissions(preset);
    final rawPermissions =
        (json["permissions"] as Map?)?.cast<String, dynamic>();

    return MultiSessionMember(
      id: json["id"] as String,
      name: json["name"] as String,
      role: json["role"] as String,
      preset: preset,
      permissions: {
        for (final permission in MultiSessionPermission.values)
          permission: rawPermissions?.containsKey(permission.name) == true
              ? rawPermissions![permission.name] == true
              : defaults[permission] == true,
      },
      images: _parseImages(json),
    );
  }
}

class MultiSessionSuggestion {
  final String id;
  final SpotubeFullTrackObject track;
  final String suggestedBy;
  final int createdAt;
  final int voteCount;
  final List<String> voterIds;

  const MultiSessionSuggestion({
    required this.id,
    required this.track,
    required this.suggestedBy,
    required this.createdAt,
    required this.voteCount,
    required this.voterIds,
  });

  factory MultiSessionSuggestion.fromJson(Map<String, dynamic> json) {
    final voterIds = (json["voterIds"] as List? ?? const [])
        .map((value) => value.toString())
        .toList();

    return MultiSessionSuggestion(
      id: json["id"] as String,
      track: SpotubeTrackObject.fromJson(
        (json["track"] as Map).cast<String, dynamic>(),
      ) as SpotubeFullTrackObject,
      suggestedBy: json["suggestedBy"] as String,
      createdAt: json["createdAt"] as int? ?? 0,
      voteCount: json["voteCount"] as int? ?? voterIds.length,
      voterIds: voterIds,
    );
  }
}

class MultiSessionRoomMetadata {
  final String code;
  final int members;
  final String? roomId;

  const MultiSessionRoomMetadata({
    required this.code,
    required this.members,
    this.roomId,
  });

  factory MultiSessionRoomMetadata.fromJson(Map<String, dynamic> json) {
    return MultiSessionRoomMetadata(
      code: json["code"] as String,
      members: json["members"] as int? ?? 0,
      roomId: json["roomId"] as String?,
    );
  }
}

class MultiSessionInvite {
  final String code;
  final String relayUrl;
  final MultiSessionRoomMetadata? metadata;
  final String? error;

  const MultiSessionInvite({
    required this.code,
    required this.relayUrl,
    this.metadata,
    this.error,
  });

  Uri toUri() {
    return Uri(
      scheme: "spotube",
      host: "multi-session",
      path: "/join",
      queryParameters: {
        "code": code,
        "relay": relayUrl,
      },
    );
  }

  MultiSessionInvite copyWith({
    String? code,
    String? relayUrl,
    MultiSessionRoomMetadata? metadata,
    String? error,
    bool clearError = false,
  }) {
    return MultiSessionInvite(
      code: code ?? this.code,
      relayUrl: relayUrl ?? this.relayUrl,
      metadata: metadata ?? this.metadata,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class MultiSessionRoomSnapshot {
  final String roomId;
  final String code;
  final int sequence;
  final List<Map<String, dynamic>> queue;
  final String? activeTrackId;
  final SpotubeAudioSourceMatchObject? activeSource;
  final int positionMs;
  final bool playing;
  final List<MultiSessionMember> members;
  final List<MultiSessionSuggestion> suggestions;
  final bool communityQueueEnabled;

  const MultiSessionRoomSnapshot({
    required this.roomId,
    required this.code,
    required this.sequence,
    required this.queue,
    required this.activeTrackId,
    required this.activeSource,
    required this.positionMs,
    required this.playing,
    required this.members,
    required this.suggestions,
    required this.communityQueueEnabled,
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
      activeSource: json["activeSource"] is Map
          ? SpotubeAudioSourceMatchObject.fromJson(
              (json["activeSource"] as Map).cast<String, dynamic>(),
            )
          : null,
      positionMs: json["positionMs"] as int? ?? 0,
      playing: json["playing"] == true,
      members: (json["members"] as List? ?? [])
          .cast<Map>()
          .map((item) =>
              MultiSessionMember.fromJson(item.cast<String, dynamic>()))
          .toList(),
      suggestions: (json["suggestions"] as List? ?? [])
          .cast<Map>()
          .map(
            (item) => MultiSessionSuggestion.fromJson(
              item.cast<String, dynamic>(),
            ),
          )
          .toList(),
      communityQueueEnabled: json["communityQueueEnabled"] != false,
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
  final MultiSessionInvite? pendingInvite;
  final MultiSessionUiNotice? notice;

  const MultiSessionState({
    this.roomId,
    this.code,
    this.token,
    this.memberId,
    this.snapshot,
    this.connected = false,
    this.connecting = false,
    this.error,
    this.pendingInvite,
    this.notice,
  });

  MultiSessionMember? get currentMember {
    if (memberId == null || snapshot == null) return null;
    return snapshot!.members
        .where((member) => member.id == memberId)
        .firstOrNull;
  }

  bool get isHost => currentMember?.role == "host";

  bool can(MultiSessionPermission permission) {
    return isHost || currentMember?.permissions[permission] == true;
  }

  MultiSessionSuggestion? get topSuggestion {
    final suggestions =
        snapshot?.suggestions ?? const <MultiSessionSuggestion>[];
    if (suggestions.isEmpty) return null;

    return suggestions.sorted((a, b) {
      final byVotes = b.voteCount.compareTo(a.voteCount);
      if (byVotes != 0) return byVotes;
      return a.createdAt.compareTo(b.createdAt);
    }).firstOrNull;
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
    MultiSessionInvite? pendingInvite,
    MultiSessionUiNotice? notice,
    bool clearRoom = false,
    bool clearError = false,
    bool clearInvite = false,
    bool clearNotice = false,
  }) {
    if (clearRoom) {
      return MultiSessionState(
        error: clearError ? null : error,
        pendingInvite: clearInvite ? null : pendingInvite ?? this.pendingInvite,
        notice: clearNotice ? null : notice ?? this.notice,
      );
    }

    return MultiSessionState(
      roomId: roomId ?? this.roomId,
      code: code ?? this.code,
      token: token ?? this.token,
      memberId: memberId ?? this.memberId,
      snapshot: snapshot ?? this.snapshot,
      connected: connected ?? this.connected,
      connecting: connecting ?? this.connecting,
      error: clearError ? null : error ?? this.error,
      pendingInvite: clearInvite ? null : pendingInvite ?? this.pendingInvite,
      notice: clearNotice ? null : notice ?? this.notice,
    );
  }
}

MultiSessionInvite? parseMultiSessionInviteUri(String uriString) {
  final uri = Uri.tryParse(uriString);
  if (uri == null || uri.scheme != "spotube") return null;
  if (uri.host != "multi-session") return null;
  if (uri.path != "/join") return null;

  final code = uri.queryParameters["code"]?.trim().toUpperCase();
  final relayUrl = uri.queryParameters["relay"]?.trim();
  if (code == null || code.isEmpty || relayUrl == null || relayUrl.isEmpty) {
    return null;
  }

  return MultiSessionInvite(code: code, relayUrl: relayUrl);
}

String encodeRoomEvent(String type, Object? data) {
  return jsonEncode({"type": type, "data": data});
}
