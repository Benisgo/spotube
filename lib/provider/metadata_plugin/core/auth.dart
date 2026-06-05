import 'dart:async';

import 'package:riverpod/riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/services/logger/logger.dart';

class MetadataPluginAuthenticatedNotifier extends AsyncNotifier<bool> {
  @override
  FutureOr<bool> build() async {
    final defaultPluginConfig = ref.watch(metadataPluginsProvider);
    if (defaultPluginConfig.asData?.value.defaultMetadataPluginConfig?.abilities
            .contains(PluginAbilities.authentication) !=
        true) {
      return false;
    }

    final defaultPlugin = await ref
        .watch(metadataPluginProvider.future)
        .timeout(const Duration(seconds: 10), onTimeout: () => null);
    if (defaultPlugin == null) {
      return false;
    }

    final sub = defaultPlugin.auth.authStateStream.listen((event) {
      state = AsyncData(defaultPlugin.auth.isAuthenticated());
    });

    ref.onDispose(() {
      sub.cancel();
    });

    try {
      return defaultPlugin.auth.isAuthenticated();
    } catch (error, stackTrace) {
      await AppLogger.reportError(error, stackTrace);
      return false;
    }
  }
}

final metadataPluginAuthenticatedProvider =
    AsyncNotifierProvider<MetadataPluginAuthenticatedNotifier, bool>(
  MetadataPluginAuthenticatedNotifier.new,
);

class AudioSourcePluginAuthenticatedNotifier extends AsyncNotifier<bool> {
  @override
  FutureOr<bool> build() async {
    final defaultPluginConfig = ref.watch(metadataPluginsProvider);
    if (defaultPluginConfig
            .asData?.value.defaultAudioSourcePluginConfig?.abilities
            .contains(PluginAbilities.authentication) !=
        true) {
      return false;
    }

    final defaultPlugin = await ref
        .watch(audioSourcePluginProvider.future)
        .timeout(const Duration(seconds: 10), onTimeout: () => null);
    if (defaultPlugin == null) {
      return false;
    }

    final sub = defaultPlugin.auth.authStateStream.listen((event) {
      state = AsyncData(defaultPlugin.auth.isAuthenticated());
    });

    ref.onDispose(() {
      sub.cancel();
    });

    try {
      return defaultPlugin.auth.isAuthenticated();
    } catch (error, stackTrace) {
      await AppLogger.reportError(error, stackTrace);
      return false;
    }
  }
}

final audioSourcePluginAuthenticatedProvider =
    AsyncNotifierProvider<AudioSourcePluginAuthenticatedNotifier, bool>(
  AudioSourcePluginAuthenticatedNotifier.new,
);
