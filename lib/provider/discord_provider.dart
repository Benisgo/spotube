import 'dart:async';

import 'package:flutter_discord_rpc/flutter_discord_rpc.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/utils/platform.dart';

class DiscordNotifier extends AsyncNotifier<void> {
  FlutterDiscordRPC? _rpcOrNull() {
    try {
      return FlutterDiscordRPC.instance;
    } catch (_) {
      return null;
    }
  }

  @override
  FutureOr<void> build() async {
    if (!kIsDesktop) return;

    final rpc = _rpcOrNull();
    if (rpc == null) return;

    final enabled = ref.watch(
        userPreferencesProvider.select((s) => s.discordPresence && kIsDesktop));

    var lastPosition = audioPlayer.position;

    final subscriptions = [
      rpc.isConnectedStream.listen((connected) async {
        try {
          final playback = ref.read(audioPlayerProvider);
          if (connected && playback.activeTrack != null) {
            await updatePresence(playback.activeTrack!);
          }
        } catch (e, stack) {
          AppLogger.reportError(e, stack);
        }
      }),
      audioPlayer.playerStateStream.listen((state) async {
        try {
          final playback = ref.read(audioPlayerProvider);
          if (playback.activeTrack == null) return;

          await updatePresence(ref.read(audioPlayerProvider).activeTrack!);
        } catch (e, stack) {
          AppLogger.reportError(e, stack);
        }
      }),
      audioPlayer.positionStream.listen((position) async {
        try {
          final playback = ref.read(audioPlayerProvider);
          if (playback.activeTrack != null) {
            final diff = position.inMilliseconds - lastPosition.inMilliseconds;
            if (diff > 500 || diff < -500) {
              await updatePresence(ref.read(audioPlayerProvider).activeTrack!);
            }
          }
          lastPosition = position;
        } catch (e, stack) {
          AppLogger.reportError(e, stack);
        }
      })
    ];

    ref.onDispose(() async {
      for (final subscription in subscriptions) {
        subscription.cancel();
      }
      await clear();
      await close();
      final rpc = _rpcOrNull();
      if (rpc != null) {
        await rpc.dispose();
      }
    });

    if (!enabled && rpc.isConnected) {
      await clear();
      await close();
    } else if (enabled) {
      await rpc.connect(autoRetry: true);
    }
  }

  Future<void> updatePresence(SpotubeTrackObject track) async {
    if (!kIsDesktop) return;
    final rpc = _rpcOrNull();
    if (rpc == null || rpc.isConnected == false) return;
    final artistNames = track.artists.asString();
    final isPlaying = audioPlayer.isPlaying;
    final position = audioPlayer.position;

    await rpc.setActivity(
      activity: RPCActivity(
        details: track.name,
        state: artistNames,
        assets: RPCAssets(
          largeImage:
              track.album.images.firstOrNull?.url ?? "spotube-logo-foreground",
          largeText: track.album.name,
          smallImage: "spotube-logo-foreground",
          smallText: "Spotube",
        ),
        buttons: [
          RPCButton(
            label: "Listen on Spotube",
            url: track.externalUri,
          ),
        ],
        timestamps: RPCTimestamps(
          start: isPlaying
              ? DateTime.now().millisecondsSinceEpoch - position.inMilliseconds
              : null,
        ),
        activityType: ActivityType.listening,
      ),
    );
  }

  Future<void> clear() async {
    if (!kIsDesktop) return;
    final rpc = _rpcOrNull();
    if (rpc == null) return;
    await rpc.clearActivity();
  }

  Future<void> close() async {
    if (!kIsDesktop) return;
    final rpc = _rpcOrNull();
    if (rpc == null) return;
    await rpc.disconnect();
  }
}

final discordProvider =
    AsyncNotifierProvider<DiscordNotifier, void>(() => DiscordNotifier());
