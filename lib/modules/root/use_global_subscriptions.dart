import 'dart:async';
import 'dart:collection';

import 'package:collection/collection.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/models/multi_session/multi_session.dart';
import 'package:spotube/modules/metadata_plugins/plugin_update_available_dialog.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/provider/metadata_plugin/updater/update_checker.dart';
import 'package:spotube/provider/multi_session/multi_session.dart';
import 'package:spotube/provider/server/routes/connect.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/connectivity_adapter.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/utils/service_utils.dart';

const _maxGlobalToastsPerWindow = 4;
const _globalToastWindow = Duration(seconds: 8);

final Queue<DateTime> _globalToastTimestamps = Queue<DateTime>();

void useGlobalSubscriptions(WidgetRef ref) {
  final context = useContext();
  final theme = Theme.of(context);
  final connectRoutes = ref.watch(serverConnectRoutesProvider);
  final multiSessionState = ref.watch(multiSessionProvider);

  MultiSessionMember? memberById(
    MultiSessionRoomSnapshot? snapshot,
    String? memberId,
  ) {
    if (snapshot == null || memberId == null) return null;
    return snapshot.members
        .where((member) => member.id == memberId)
        .firstOrNull;
  }

  void queueToast(VoidCallback show) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      final now = DateTime.now();
      while (_globalToastTimestamps.isNotEmpty &&
          now.difference(_globalToastTimestamps.first) > _globalToastWindow) {
        _globalToastTimestamps.removeFirst();
      }

      if (_globalToastTimestamps.length >= _maxGlobalToastsPerWindow) {
        return;
      }

      _globalToastTimestamps.addLast(now);
      show();
    });
  }

  void showDestructiveToast(String message) {
    queueToast(() {
      showToast(
        context: context,
        location: ToastLocation.topCenter,
        builder: (context, overlay) {
          return SurfaceCard(
            fillColor: theme.colorScheme.destructive,
            filled: true,
            child: Basic(
              leading: const Icon(
                SpotubeIcons.error,
                color: Colors.white,
              ),
              title: Text(
                message,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          );
        },
      );
    });
  }

  void showInformationalToast(String message) {
    queueToast(() {
      showToast(
        context: context,
        location: ToastLocation.topRight,
        builder: (context, overlay) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: theme.colorScheme.muted.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.foreground,
              ),
            ),
          );
        },
      );
    });
  }

  final previousSnapshot = usePrevious(multiSessionState.snapshot);
  final lastRoomToast = useRef<String?>(null);

  useEffect(() {
    final notice = multiSessionState.notice;
    if (notice == null) return null;

    if (notice.destructive) {
      showDestructiveToast(notice.message);
    } else {
      showInformationalToast(notice.message);
    }
    return null;
  }, [multiSessionState.notice?.id]);

  useEffect(() {
    final snapshot = multiSessionState.snapshot;
    if (snapshot == null || previousSnapshot == null) return null;

    final previousMemberIds = previousSnapshot.members.map((m) => m.id).toSet();
    final currentMemberIds = snapshot.members.map((m) => m.id).toSet();

    for (final joined in snapshot.members.where(
      (member) => !previousMemberIds.contains(member.id),
    )) {
      final message = "${joined.name} joined the room";
      if (message != lastRoomToast.value) {
        lastRoomToast.value = message;
        showInformationalToast(message);
      }
    }

    for (final left in previousSnapshot.members.where(
      (member) => !currentMemberIds.contains(member.id),
    )) {
      final message = "${left.name} left the room";
      if (message != lastRoomToast.value) {
        lastRoomToast.value = message;
        showInformationalToast(message);
      }
    }

    final previousTopSuggestion = previousSnapshot.suggestions.firstOrNull;
    final currentTopSuggestion = snapshot.suggestions.firstOrNull;
    if (currentTopSuggestion != null &&
        currentTopSuggestion.id != previousTopSuggestion?.id) {
      final actor = memberById(snapshot, currentTopSuggestion.suggestedBy)?.name;
      final message = actor == null
          ? "${currentTopSuggestion.track.name} was suggested"
          : "${currentTopSuggestion.track.name} was suggested by $actor";
      if (message != lastRoomToast.value) {
        lastRoomToast.value = message;
        showInformationalToast(message);
      }
    }

    return null;
  }, [multiSessionState.snapshot?.sequence]);

  useEffect(() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      ServiceUtils.checkForUpdates(context, ref);

      PluginUpdateAvailable? pluginUpdate;

      try {
        pluginUpdate =
            await ref.read(metadataPluginUpdateCheckerProvider.future);
      } catch (error, stackTrace) {
        await AppLogger.reportError(
          error,
          stackTrace,
          "Global metadata plugin update subscription failed",
        );
      }

      if (pluginUpdate != null) {
        final pluginConfig = await ref.read(metadataPluginsProvider.future);
        if (context.mounted) {
          showDialog(
            context: context,
            builder: (context) => MetadataPluginUpdateAvailableDialog(
              plugin: pluginConfig.defaultMetadataPluginConfig!,
              update: pluginUpdate!,
            ),
          );
        }
      }
    });

    StreamSubscription? audioPlayerSubscription;
    bool pausedByStream = false;
    String? lastPlaybackError;
    DateTime? lastPlaybackErrorAt;
    bool skippedAfterPlaybackError = false;

    String? buildFriendlyPlaybackError(String rawError) {
      final lower = rawError.toLowerCase();
      if (lower.contains("failed to open http://localhost") ||
          lower.contains("failed to open http://127.0.0.1")) {
        final activeTrack = ref.read(audioPlayerProvider).activeTrack;
        final trackName = activeTrack?.name ?? "This track";
        return "$trackName couldn't be streamed right now. Try another source or YouTube engine.";
      }

      return null;
    }

    final subscriptions = [
      ConnectionCheckerService.instance.onConnectivityChanged
          .listen((connected) async {
        audioPlayerSubscription?.cancel();

        /// Pausing or resuming based on connectivity to avoid MPV skipping
        /// audio while retrying to connect
        if (audioPlayer.currentIndex >= 0) {
          if (connected && audioPlayer.isPaused && pausedByStream) {
            await audioPlayer.resume();
            pausedByStream = false;
          } else if (!connected && audioPlayer.isPlaying) {
            if ((audioPlayer.bufferedPosition - const Duration(seconds: 1)) <=
                audioPlayer.position) {
              await audioPlayer.pause();
              pausedByStream = true;
            } else {
              audioPlayerSubscription =
                  audioPlayer.positionStream.listen((position) async {
                if (ConnectionCheckerService.instance.isConnectedSync) return;

                final bufferedPosition =
                    audioPlayer.bufferedPosition - const Duration(seconds: 1);
                final duration =
                    audioPlayer.duration - const Duration(seconds: 1);

                if (bufferedPosition <= position || position >= duration) {
                  audioPlayer.pause();
                  pausedByStream = true;
                }
              });
            }
          }
        }

        // Show notification for connection related issues
        if (!context.mounted) return;

        queueToast(() {
          showToast(
            context: context,
            location: ToastLocation.bottomCenter,
            builder: (context, overlay) {
              if (connected) {
                return SurfaceCard(
                  child: Basic(
                    leading: const Icon(SpotubeIcons.wifi),
                    title: Text(context.l10n.connection_restored),
                  ),
                );
              }

              return SurfaceCard(
                fillColor: theme.colorScheme.destructive,
                filled: true,
                child: Basic(
                  leading: const Icon(
                    SpotubeIcons.noWifi,
                    color: Colors.white,
                  ),
                  trailing: Text(
                    context.l10n.you_are_offline,
                    style: const TextStyle(
                      color: Colors.white,
                    ),
                  ),
                ),
              );
            },
          );
        });
      }),
      connectRoutes.connectClientStream.listen((clientOrigin) {
        if (!context.mounted) return;
        queueToast(() {
          showToast(
            context: context,
            location: ToastLocation.topRight,
            builder: (context, overlay) {
              return SurfaceCard(
                fillColor: Colors.yellow[600],
                filled: true,
                child: Basic(
                  leading: const Icon(
                    SpotubeIcons.error,
                    color: Colors.black,
                  ),
                  title: Text(
                    context.l10n.connect_client_alert(clientOrigin),
                    style: const TextStyle(color: Colors.black),
                  ),
                ),
              );
            },
          );
        });
      }),
      audioPlayer.errorStream.listen((error) {
        final message = buildFriendlyPlaybackError(error);
        final now = DateTime.now();
        final isRepeatedRecentError =
            message != null &&
            message == lastPlaybackError &&
            lastPlaybackErrorAt != null &&
            now.difference(lastPlaybackErrorAt!) < const Duration(seconds: 8);
        if (!context.mounted ||
            message == null ||
            isRepeatedRecentError) {
          return;
        }

        lastPlaybackError = message;
        lastPlaybackErrorAt = now;
        showDestructiveToast(message);
        if (!skippedAfterPlaybackError) {
          skippedAfterPlaybackError = true;
          unawaited(audioPlayer.skipToNext());
        }
      })
    ];

    return () {
      for (final subscription in subscriptions) {
        subscription.cancel();
      }
    };
  }, []);
}
