part of 'multi_session.dart';

/// Member-facing actions for [MultiSessionNotifier].
///
/// Owns UI notices + permission guards, member lookups, invite resolution,
/// local playback pause/preview controls, and the member/queue/suggestion
/// mutation commands that are broadcast to the room. Kept in a separate
/// `part` file so the notifier core stays focused on wiring streams in
/// [build].
mixin MultiSessionMembers on MultiSessionRelay {
  MultiSessionUiNotice _buildNotice(
    String message, {
    bool destructive = false,
  }) {
    return MultiSessionUiNotice(
      message: message,
      destructive: destructive,
      id: DateTime.now().microsecondsSinceEpoch,
    );
  }

  void _pushNotice(
    String message, {
    bool destructive = false,
  }) {
    state = state.copyWith(
      notice: _buildNotice(message, destructive: destructive),
    );
  }

  bool _guardPermission(
    MultiSessionPermission permission,
    String actionLabel,
  ) {
    if (state.can(permission)) return true;

    _pushNotice(
      "You don't have permission to $actionLabel in this room.",
      destructive: true,
    );
    return false;
  }

  String get _actorName => state.currentMember?.name ?? "You";

  MultiSessionMember? _memberById(String memberId) {
    return state.snapshot?.members
        .where((member) => member.id == memberId)
        .firstOrNull;
  }

  Uri? get inviteUri {
    final code = state.code;
    final relayUrl = _relayUrl;
    if (code == null || code.isEmpty || relayUrl.isEmpty) return null;
    return MultiSessionInvite(code: code, relayUrl: relayUrl).toUri();
  }

  Future<MultiSessionRoomMetadata?> _fetchRoomMetadata(
    String code, {
    required String relayUrl,
  }) async {
    final relayConfigurationError = _relayConfigurationError(relayUrl);
    if (relayConfigurationError != null) {
      throw Exception(relayConfigurationError);
    }

    final response =
        await http.get(_relayUri("/rooms/$code", relayUrl: relayUrl));
    if (response.statusCode >= 400) {
      throw Exception(response.body);
    }

    return MultiSessionRoomMetadata.fromJson(
      (jsonDecode(response.body) as Map).cast<String, dynamic>(),
    );
  }

  Future<void> resolveInviteUri(String uriString) async {
    final invite = parseMultiSessionInviteUri(uriString);
    if (invite == null) return;

    state = state.copyWith(pendingInvite: invite, clearError: true);

    try {
      final metadata = await _fetchRoomMetadata(
        invite.code,
        relayUrl: invite.relayUrl,
      );
      state = state.copyWith(
        pendingInvite: invite.copyWith(metadata: metadata, clearError: true),
      );
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      state = state.copyWith(
        pendingInvite: invite.copyWith(error: _friendlyError(e)),
      );
    }
  }

  void clearPendingInvite() {
    state = state.copyWith(clearInvite: true);
  }

  Future<void> setLocalPlaybackPaused(bool paused) async {
    if (!state.connected || state.can(MultiSessionPermission.controlPlayback)) {
      return;
    }

    state = state.copyWith(locallyPaused: paused);
    if (paused) {
      // Actually pause the local player (not just mute) so a listener's
      // Pause button behaves like a real pause. Snapshots never resume us
      // while locallyPaused is set, so the pause persists across the room's
      // position ticks. Call pause() unconditionally (it is idempotent): a
      // stale audioPlayer.isPlaying must not let a mid-apply snapshot skip
      // the listener's pause.
      await audioPlayer.pause();
    } else {
      // Resume and catch up to the room's authoritative position, so the
      // listener rejoins the live playback instead of resuming from where
      // they paused (which could be minutes behind).
      final snapshot = state.snapshot;
      if (snapshot != null && snapshot.playing) {
        if (!audioPlayer.isPlaying) {
          await audioPlayer.resume();
        }
        final driftMs =
            (snapshot.positionMs - audioPlayer.position.inMilliseconds).abs();
        if (driftMs >= MultiSessionSync._remoteSeekThresholdMs) {
          await audioPlayer.seek(Duration(milliseconds: snapshot.positionMs));
        }
      }
    }
  }

  Future<void> toggleLocalPlaybackPaused() async {
    await setLocalPlaybackPaused(!state.locallyPaused);
  }

  Future<void> setPreviewSilenced(bool silenced) async {
    state = state.copyWith(previewSilenced: silenced);
  }

  void setMemberPreset(String memberId, MultiSessionMemberPreset preset) {
    if (!_guardPermission(
      MultiSessionPermission.manageMembers,
      "change member roles",
    )) {
      return;
    }
    final memberName = _memberById(memberId)?.name ?? "That member";
    _pushNotice("$memberName is now ${preset.label} by $_actorName");
    _send("permissions", {
      "memberId": memberId,
      "preset": preset.name,
    });
  }

  void setMemberPermissions(
    String memberId,
    Map<MultiSessionPermission, bool> permissions,
  ) {
    if (!_guardPermission(
      MultiSessionPermission.manageMembers,
      "change member permissions",
    )) {
      return;
    }
    final memberName = _memberById(memberId)?.name ?? "That member";
    _pushNotice("Permissions updated for $memberName by $_actorName");
    _send("permissions", {
      "memberId": memberId,
      "permissions": {
        for (final MapEntry(:key, :value) in permissions.entries)
          key.name: value,
      },
    });
  }

  void kickMember(String memberId) {
    if (!_guardPermission(
      MultiSessionPermission.manageMembers,
      "kick a member",
    )) {
      return;
    }
    final memberName = _memberById(memberId)?.name ?? "That member";
    _pushNotice("$memberName was kicked by $_actorName");
    _send("kick", {"memberId": memberId});
  }

  void setCommunityQueueEnabled(bool enabled) {
    if (!_guardPermission(
      MultiSessionPermission.editQueue,
      "edit the queue",
    )) {
      return;
    }
    _pushNotice(
      "Community queue ${enabled ? "enabled" : "disabled"} by $_actorName",
    );
    _send("roomSettings", {"communityQueueEnabled": enabled});
  }

  void setAutoAcceptSuggestedTracksEnabled(bool enabled) {
    if (!_guardPermission(
      MultiSessionPermission.editQueue,
      "edit the queue",
    )) {
      return;
    }
    _pushNotice(
      "Auto accept suggested tracks ${enabled ? "enabled" : "disabled"} by $_actorName",
    );
    _send("roomSettings", {"autoAcceptSuggestedTracks": enabled});
  }

  void setDiscordJoinEnabled(bool enabled) {
    if (!_guardPermission(
      MultiSessionPermission.editQueue,
      "edit room settings",
    )) {
      return;
    }
    _pushNotice(
      "Discord room joining ${enabled ? "enabled" : "disabled"} by $_actorName",
    );
    _send("roomSettings", {"discordJoinEnabled": enabled});
  }

  void suggestTrack(SpotubeFullTrackObject track) {
    if (!_guardPermission(
      MultiSessionPermission.suggestTracks,
      "suggest tracks",
    )) {
      return;
    }
    _pushNotice("${track.name} suggested by $_actorName");
    _send("suggestion:add", {"track": track.toJson()});
  }

  void voteSuggestion(String suggestionId) {
    if (!_guardPermission(
      MultiSessionPermission.voteTracks,
      "vote on suggestions",
    )) {
      return;
    }
    _pushNotice("Suggestion upvoted by $_actorName");
    _send("suggestion:vote", {"suggestionId": suggestionId});
  }

  void removeSuggestion(String suggestionId) {
    if (!_guardPermission(
      MultiSessionPermission.editQueue,
      "remove suggestions",
    )) {
      return;
    }
    _pushNotice("Suggestion removed by $_actorName");
    _send("suggestion:remove", {"suggestionId": suggestionId});
  }

  void promoteSuggestion(String suggestionId) {
    if (!_guardPermission(
      MultiSessionPermission.editQueue,
      "promote suggestions",
    )) {
      return;
    }
    _pushNotice("Suggestion promoted by $_actorName");
    _send("suggestion:promote", {"suggestionId": suggestionId});
  }
}
