import 'dart:convert';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/metadata/errors/exceptions.dart';
import 'package:spotube/services/metadata/metadata.dart';

part 'quality_presets.g.dart';
part 'quality_presets.freezed.dart';

@freezed
class AudioSourcePresetsState with _$AudioSourcePresetsState {
  factory AudioSourcePresetsState({
    @Default([]) final List<SpotubeAudioSourceContainerPreset> presets,
    @Default(0) final int selectedStreamingQualityIndex,
    @Default(0) final int selectedStreamingContainerIndex,
    @Default(0) final int selectedDownloadingQualityIndex,
    @Default(0) final int selectedDownloadingContainerIndex,
  }) = _AudioSourcePresetsState;

  factory AudioSourcePresetsState.fromJson(Map<String, dynamic> json) =>
      _$AudioSourcePresetsStateFromJson(json);
}

class AudioSourceAvailableQualityPresetsNotifier
    extends Notifier<AudioSourcePresetsState> {
  @override
  build() {
    final audioSourceSnapshot = ref.watch(audioSourcePluginProvider);
    final audioSourceConfigSnapshot = ref.watch(
      metadataPluginsProvider.select((data) =>
          data.whenData((value) => value.defaultAudioSourcePluginConfig)),
    );

    _initialize(audioSourceSnapshot, audioSourceConfigSnapshot);

    // Use a large demuxer read-ahead buffer (10MB) so mpv loads the full
    // song ahead — full seekbar highlight and faster disk-cache completion.
    audioPlayer.setDemuxerBufferSize(10 * 1024 * 1024);

    return AudioSourcePresetsState();
  }

  void _initialize(
    AsyncValue<MetadataPlugin?> audioSourceSnapshot,
    AsyncValue<PluginConfiguration?> audioSourceConfigSnapshot,
  ) async {
    audioSourceConfigSnapshot.whenData((audioSourceConfig) {
      audioSourceSnapshot.whenData((audioSource) async {
        if (audioSource == null || audioSourceConfig == null) {
          throw MetadataPluginException.noDefaultAudioSourcePlugin();
        }
        final preferences = await SharedPreferences.getInstance();
        final persistedStateStr =
            preferences.getString("audioSourceState-${audioSourceConfig.slug}");

        if (persistedStateStr != null) {
          state =
              AudioSourcePresetsState.fromJson(jsonDecode(persistedStateStr))
                  .copyWith(
            presets: audioSource.audioSource.supportedPresets,
          );
        } else {
          state = AudioSourcePresetsState(
            presets: audioSource.audioSource.supportedPresets,
          );
        }
      });
    });
  }

  void setSelectedStreamingContainerIndex(int index) {
    state = state.copyWith(
      selectedStreamingContainerIndex: index,
      selectedStreamingQualityIndex:
          0, // Resetting both because it's a different quality
    );
    _updatePreferences();
  }

  void setSelectedStreamingQualityIndex(int index) {
    state = state.copyWith(selectedStreamingQualityIndex: index);
    _updatePreferences();
  }

  void setSelectedDownloadingContainerIndex(int index) {
    state = state.copyWith(
      selectedDownloadingContainerIndex: index,
      selectedDownloadingQualityIndex:
          0, // Resetting both because it's a different quality
    );
    _updatePreferences();
  }

  void setSelectedDownloadingQualityIndex(int index) {
    state = state.copyWith(selectedDownloadingQualityIndex: index);
    _updatePreferences();
  }

  void _updatePreferences() async {
    final audioSourceConfig = await ref.read(metadataPluginsProvider
        .selectAsync((data) => data.defaultAudioSourcePluginConfig));
    if (audioSourceConfig == null) {
      throw MetadataPluginException.noDefaultAudioSourcePlugin();
    }

    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      "audioSourceState-${audioSourceConfig.slug}",
      jsonEncode(state),
    );
  }
}

final audioSourcePresetsProvider = NotifierProvider<
    AudioSourceAvailableQualityPresetsNotifier, AudioSourcePresetsState>(
  () => AudioSourceAvailableQualityPresetsNotifier(),
);
