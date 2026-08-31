import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/models/multi_session/multi_session.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/audio_player/audio_player_service_provider.dart';
import 'package:spotube/provider/metadata_plugin/core/user.dart';
import 'package:spotube/provider/server/sourced_track_provider.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/device_info/device_info.dart';
import 'package:spotube/services/kv_store/kv_store.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

part 'multi_session_sync.dart';
part 'multi_session_relay.dart';
part 'multi_session_members.dart';

bool _looksLikeLocalRelayHost(String value) {
  final lower = value.toLowerCase();
  return lower.startsWith("localhost") ||
      lower.startsWith("127.") ||
      lower.startsWith("[::1]") ||
      lower.startsWith("::1");
}

/// Normalizes a user-entered relay URL (no scheme -> https, ws/wss -> http/https).
String normalizeRelayUrl(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return "";

  final parsed = Uri.tryParse(trimmed);
  final looksLikeAuthority = trimmed.contains("://");
  if (parsed != null && parsed.hasScheme && looksLikeAuthority) {
    return switch (parsed.scheme.toLowerCase()) {
      "ws" => parsed.replace(scheme: "http").toString(),
      "wss" => parsed.replace(scheme: "https").toString(),
      _ => parsed.toString(),
    };
  }

  final scheme = _looksLikeLocalRelayHost(trimmed) ? "http" : "https";
  final normalized = Uri.tryParse("$scheme://$trimmed");
  return normalized?.toString() ?? trimmed;
}

/// Multi-session listening-room state + room sync.
///
/// The class itself is deliberately lean: it only wires the stream listeners
/// in [build]. The actual behavior lives in three `part` mixins, each with a
/// single responsibility:
/// - [MultiSessionSync] — snapshot reconciliation + shared mutable state.
/// - [MultiSessionRelay] — relay transport + room lifecycle.
/// - [MultiSessionMembers] — member/queue/suggestion actions + notices.
class MultiSessionNotifier extends Notifier<MultiSessionState>
    with MultiSessionSync, MultiSessionRelay, MultiSessionMembers {
  @override
  MultiSessionState build() {
    listenSelf((previous, next) {
      audioPlayer.setSuppressCompletedAdvanceRecovery(
        next.connected && !next.can(MultiSessionPermission.controlPlayback),
      );
      if (previous?.locallyMuted != next.locallyMuted) {
        unawaited(_syncLocalMuteState());
      }
    });

    ref.listen(audioPlayerProvider, (previous, next) {
      if (!_canEditQueue) return;
      // Never re-broadcast changes that we ourselves caused while applying a
      // snapshot (e.g. the jumpTo for a remote skip). Those flow back through
      // the playlist/index streams mid-apply and would otherwise echo as if
      // they were our own action.
      if (_applyingRemote) return;

      final previousIds = previous?.tracks.map((track) => track.id).join(",");
      final nextIds = next.tracks.map((track) => track.id).join(",");
      if (previousIds != nextIds ||
          previous?.currentIndex != next.currentIndex) {
        final localTrackIds =
            next.tracks.map((track) => track.id).toList(growable: false);
        // Compare against the snapshot we actually APPLIED (not the newest
        // state.snapshot, which can be a newer trivial tick), so a queue that
        // still matches our applied queue is recognized as a sync echo.
        final syncSnapshot = _lastAppliedSnapshot ?? state.snapshot;
        final remoteTrackIds = _queueIds(syncSnapshot?.queue ?? const []);
        final activeIndex = syncSnapshot?.activeTrackId == null
            ? 0
            : remoteTrackIds.indexOf(syncSnapshot!.activeTrackId!);
        final index = activeIndex < 0 ? 0 : activeIndex;

        final isSnapshotSync = MultiSessionSync._stringListEquality
                .equals(localTrackIds, remoteTrackIds) &&
            next.currentIndex == index;

        if (isSnapshotSync) return;

        // Genuine local queue change (play/load/edit), not a snapshot sync.
        if (!_applyingRemote) _lastLocalActionAt = DateTime.now();

        if (previousIds != nextIds) {
          final previousTrackIds =
              previous?.tracks.map((track) => track.id).toSet() ?? <String>{};
          final addedTrack =
              next.tracks.whereType<SpotubeFullTrackObject>().firstWhereOrNull(
                    (track) => !previousTrackIds.contains(track.id),
                  );
          if (addedTrack != null) {
            _pushNotice("${addedTrack.name} added to queue by $_actorName");
          }
        }
        if (previousIds == nextIds &&
            previous?.currentIndex != next.currentIndex) {
          // Track advance (or jumpTo) with the SAME queue: broadcast the new
          // active track via a playback update, which updates activeTrackId /
          // position WITHOUT replacing the room's queue list. A full queue
          // push here would clobber other members' edits (e.g. a co-host's
          // "Play Next" / add that this member hasn't loaded yet).
          sendPlayback(bypassSuppress: true);
        } else {
          // Structural queue change (add/remove/reorder/load): debounce the
          // full queue push to avoid re-serializing large queues on every
          // track advance (e.g., 3000-song playlist).
          _sendQueueTimer?.cancel();
          _sendQueueTimer = Timer(const Duration(milliseconds: 200), sendQueue);
        }
      }
    });

    final playingSubscription = audioPlayer.playingStream.listen((playing) {
      if (!_canControlPlayback) return;
      // A playing/pause event triggered while we were applying a snapshot is
      // our own echo of that apply (resume/pause toward the snapshot state) —
      // never re-broadcast it.
      if (_applyingRemote) return;
      // A late media_kit event right after an apply that matches the applied
      // state is also an echo.
      if (_shouldSuppressOutboundSync &&
          _lastAppliedSnapshot?.playing == playing) {
        return;
      }
      // Genuine local play/pause (user action, or the host's completed-advance
      // recovery resuming after a track ended). Always broadcast it, even
      // within the post-apply suppression window — otherwise the "next song
      // plays but stays paused" bug happens.
      _lastLocalActionAt = DateTime.now();
      // Don't toast for the transient pause/resume that accompanies a natural
      // track change (mpv pauses at the boundary, then the completed-advance
      // recovery resumes). Only notice genuine user toggles.
      final duration = audioPlayer.duration;
      final position = audioPlayer.position;
      final atTrackBoundary = duration > Duration.zero &&
          (position >= (duration - const Duration(seconds: 2)) ||
              position <= const Duration(seconds: 1));
      if (!atTrackBoundary) {
        _pushNotice(
          playing
              ? "Playback resumed by $_actorName"
              : "Playback paused by $_actorName",
        );
      }
      _rememberObservedPosition(audioPlayer.position);
      sendPlayback(bypassSuppress: true);
    });

    final positionSubscription = audioPlayer.positionStream.listen((position) {
      if (!state.connected) return;
      final now = DateTime.now();
      final previousPositionMs = _lastObservedPositionMs;
      final previousObservedAt = _lastObservedAt;
      _rememberObservedPosition(position);

      // When the active track changed (natural end / skip), sendQueue already
      // broadcasts the new track + position. Don't fire a non-passive playback
      // send here: it could carry a stale playing=false captured during the
      // track transition and broadcast a false "paused" to the whole room.
      final currentTrackId = ref.read(audioPlayerProvider).activeTrack?.id;
      final trackChanged = currentTrackId != _lastObservedTrackId;
      _lastObservedTrackId = currentTrackId;
      if (trackChanged) return;

      if (!_canControlPlayback ||
          previousPositionMs == null ||
          previousObservedAt == null) {
        return;
      }

      if (_shouldSuppressOutboundSync) return;

      final elapsedMs = now.difference(previousObservedAt).inMilliseconds;
      final expectedPositionMs =
          previousPositionMs + (audioPlayer.isPlaying ? elapsedMs : 0);

      if ((position.inMilliseconds - expectedPositionMs).abs() > 1500) {
        // Genuine local seek/position jump (not one we applied from a snapshot).
        if (!_applyingRemote) _lastLocalActionAt = DateTime.now();
        sendPlayback();
      }
    });

    final errorSubscription = audioPlayer.errorStream.listen((error) {
      if (!state.connected || _canControlPlayback) return;

      // Error cooldown: don't pause more than once per 3s (Bug C3)
      final now = DateTime.now();
      if (_lastErrorPauseAt != null &&
          now.difference(_lastErrorPauseAt!).inMilliseconds < 3000) {
        return;
      }

      final playerState = ref.read(audioPlayerProvider);
      final currentTrackId = playerState.activeTrack?.id;
      if (currentTrackId != null) {
        _failedSessionTracks[currentTrackId] = now;
        _lastErrorPauseAt = now;
        _pushNotice("Track failed to load - playback paused",
            destructive: true);
      }
      if (audioPlayer.isPlaying) {
        audioPlayer.pause();
      }

      // Schedule retry in 3s (Bug C1): clear this track from failed set
      // and resume if the snapshot still points to it.
      _errorRetryTimer?.cancel();
      final retryTrackId = currentTrackId;
      _errorRetryTimer = Timer(const Duration(seconds: 3), () async {
        if (_closingRoom || _intentionalDisconnect || retryTrackId == null)
          return;
        _failedSessionTracks.remove(retryTrackId);
        // If the snapshot still points to this track, resume playback
        final snapshot = state.snapshot;
        if (snapshot != null &&
            snapshot.activeTrackId == retryTrackId &&
            snapshot.playing &&
            !state.locallyPaused) {
          await audioPlayer.resume();
        }
      });
    });

    _positionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!state.connected || !state.isHost) return;
      if (!_canControlPlayback) return;
      if (_shouldSuppressOutboundSync) return;
      _rememberObservedPosition(audioPlayer.position);
      // Passive, position-only sync: never carries the active track/source,
      // so it can't revert a newer track change on other members, and the
      // relay won't let it clobber a recent active seek.
      sendPlayback(passive: true);
    });

    ref.onDispose(() {
      playingSubscription.cancel();
      positionSubscription.cancel();
      errorSubscription.cancel();
      _positionTimer?.cancel();
      _reconnectTimer?.cancel();
      _errorRetryTimer?.cancel();
      _sendQueueTimer?.cancel();
      _subscription?.cancel();
      _channel?.sink.close(status.goingAway);
    });

    return const MultiSessionState();
  }
}

final multiSessionProvider =
    NotifierProvider<MultiSessionNotifier, MultiSessionState>(
  () => MultiSessionNotifier(),
);
