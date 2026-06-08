import 'package:auto_route/auto_route.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show ListTile, TextEditingController;

import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/components/adaptive/adaptive_select_tile.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/modules/settings/playback/edit_connect_port_dialog.dart';
import 'package:spotube/modules/settings/section_card_with_heading.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/modules/settings/youtube_engine_not_installed_dialog.dart';
import 'package:spotube/provider/metadata_plugin/audio_source/quality_presets.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/kv_store/kv_store.dart';
import 'package:spotube/services/youtube_engine/yt_dlp_binary.dart';
import 'package:spotube/services/youtube_engine/android_yt_dlp_engine.dart';
import 'package:spotube/services/youtube_engine/yt_dlp_auth_browser.dart';

import 'package:spotube/utils/platform.dart';

class SettingsPlaybackSection extends HookConsumerWidget {
  static const _legacyRelayUrl = "https://spotube-multi-session.workers.dev";

  const SettingsPlaybackSection({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final ytDlpAuthBrowser = useState(KVStoreService.ytDlpAuthBrowser);
    final preferences = ref.watch(userPreferencesProvider);
    final preferencesNotifier = ref.watch(userPreferencesProvider.notifier);
    final sourcePresets = ref.watch(audioSourcePresetsProvider);
    final sourcePresetsNotifier =
        ref.watch(audioSourcePresetsProvider.notifier);
    final theme = Theme.of(context);
    final relayUrl = preferences.multiSessionRelayUrl.trim();
    final relaySubtitle = relayUrl.isEmpty || relayUrl == _legacyRelayUrl
        ? "Not configured"
        : relayUrl;

    return SectionCardWithHeading(
      heading: context.l10n.playback,
      children: [
        AdaptiveSelectTile<YoutubeClientEngine>(
          secondary: const Icon(SpotubeIcons.engine),
          title: Text(context.l10n.youtube_engine),
          value: preferences.youtubeClientEngine,
          options: YoutubeClientEngine.values
              .where((e) => e.isAvailableForPlatform())
              .map((e) => SelectItemButton(
                    value: e,
                    child: Text(e.label),
                  ))
              .toList(),
          onChanged: (value) async {
            if (value == null) return;
            if (value == YoutubeClientEngine.ytDlp) {
              final isInstalled = kIsAndroid
                  ? await AndroidYtDlpEngine.isInstalled()
                  : await YtDlpBinary.ensureAvailable(downloadIfMissing: false);
              if (!isInstalled && context.mounted) {
                final hasInstalled = await showDialog<bool>(
                  context: context,
                  builder: (context) =>
                      YouTubeEngineNotInstalledDialog(engine: value),
                );
                if (hasInstalled != true) return;
              }
            }
            preferencesNotifier.setYoutubeClientEngine(value);
          },
        ),
        if (kIsDesktop)
          AdaptiveSelectTile<YtDlpAuthBrowser>(
            secondary: const Icon(SpotubeIcons.login),
            title: const Text("yt-dlp auth browser"),
            value: ytDlpAuthBrowser.value,
            options: YtDlpAuthBrowser.values
                .map(
                  (browser) => SelectItemButton(
                    value: browser,
                    child: Text(browser.label),
                  ),
                )
                .toList(),
            onChanged: (value) async {
              if (value == null) return;
              ytDlpAuthBrowser.value = value;
              await KVStoreService.setYtDlpAuthBrowser(value);
            },
          ),
        if (kIsDesktop)
          ListTile(
            leading: const Icon(SpotubeIcons.download),
            title: const Text("Re-test managed yt-dlp download"),
            subtitle: const Text(
              "Deletes Spotube's managed yt-dlp binary so the auto-download flow can be tested again",
            ),
            onTap: () async {
              final hasManagedBinary = await YtDlpBinary.hasManagedBinary();
              if (!context.mounted) return;

              final shouldRemove = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text("Re-test managed yt-dlp download"),
                  content: Text(
                    hasManagedBinary
                        ? "This will remove Spotube's managed yt-dlp binary. The next time yt-dlp is needed, Spotube will go through the auto-download flow again."
                        : "No managed yt-dlp binary is currently stored by Spotube. The next time yt-dlp is needed, Spotube will go through the auto-download flow again.",
                  ),
                  actions: [
                    Button.secondary(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: Text(context.l10n.cancel),
                    ),
                    Button.primary(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text(hasManagedBinary ? "Remove" : "OK"),
                    ),
                  ],
                ),
              );

              if (shouldRemove != true) return;

              await YtDlpBinary.removeManagedBinary();
              if (!context.mounted) return;

              showToast(
                context: context,
                builder: (context, overlay) => const SurfaceCard(
                  child: Basic(
                    leading: Icon(SpotubeIcons.download),
                    title: Text(
                      "Managed yt-dlp reset. The next yt-dlp use will trigger the auto-download flow again.",
                    ),
                  ),
                ),
              );
            },
          ),
        if (sourcePresets.presets.isNotEmpty) ...[
          AdaptiveSelectTile(
            secondary: const Icon(SpotubeIcons.plugin),
            title: Text(context.l10n.streaming_music_format),
            value: sourcePresets.selectedStreamingContainerIndex,
            options: [
              for (final MapEntry(:key, value: preset)
                  in sourcePresets.presets.asMap().entries)
                SelectItemButton(value: key, child: Text(preset.name)),
            ],
            onChanged: (value) {
              if (value == null) return;
              sourcePresetsNotifier.setSelectedStreamingContainerIndex(value);
            },
          ),
          AdaptiveSelectTile(
            secondary: const Icon(SpotubeIcons.audioQuality),
            title: Text(context.l10n.streaming_music_quality),
            value: sourcePresets.selectedStreamingQualityIndex,
            options: [
              for (final MapEntry(:key, value: quality) in sourcePresets
                  .presets[sourcePresets.selectedStreamingContainerIndex]
                  .qualities
                  .asMap()
                  .entries)
                SelectItemButton(value: key, child: Text(quality.toString())),
            ],
            onChanged: (value) {
              if (value == null) return;
              sourcePresetsNotifier.setSelectedStreamingQualityIndex(value);
            },
          ),
          AdaptiveSelectTile(
            secondary: const Icon(SpotubeIcons.plugin),
            title: Text(context.l10n.download_music_format),
            value: sourcePresets.selectedDownloadingContainerIndex,
            options: [
              for (final MapEntry(:key, value: preset)
                  in sourcePresets.presets.asMap().entries)
                SelectItemButton(value: key, child: Text(preset.name)),
            ],
            onChanged: (value) {
              if (value == null) return;
              sourcePresetsNotifier.setSelectedDownloadingContainerIndex(value);
            },
          ),
          AdaptiveSelectTile(
            secondary: const Icon(SpotubeIcons.audioQuality),
            title: Text(context.l10n.download_music_quality),
            value: sourcePresets.selectedStreamingQualityIndex,
            options: [
              for (final MapEntry(:key, value: quality) in sourcePresets
                  .presets[sourcePresets.selectedDownloadingContainerIndex]
                  .qualities
                  .asMap()
                  .entries)
                SelectItemButton(value: key, child: Text(quality.toString())),
            ],
            onChanged: (value) {
              if (value == null) return;
              sourcePresetsNotifier.setSelectedStreamingQualityIndex(value);
            },
          ),
        ],
        ListTile(
          title: Text(context.l10n.cache_music),
          subtitle: kIsMobile
              ? null
              : Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: "${context.l10n.open} "),
                      TextSpan(
                        text: context.l10n.cache_folder.toLowerCase(),
                        recognizer: TapGestureRecognizer()
                          ..onTap = preferencesNotifier.openCacheFolder,
                        style: theme.typography.normal.copyWith(
                          color: theme.colorScheme.primary,
                          decoration: TextDecoration.underline,
                        ),
                      )
                    ],
                  ),
                ),
          leading: const Icon(SpotubeIcons.cache),
          trailing: Switch(
            value: preferences.cacheMusic,
            onChanged: preferencesNotifier.setCacheMusic,
          ),
        ),
        ListTile(
          leading: const Icon(SpotubeIcons.connect),
          title: const Text("Handle Spotify links"),
          subtitle: const Text(
            "Open spotify: URIs and open.spotify.com URLs in Spotube",
          ),
          trailing: Switch(
            value: preferences.handleSpotifyLinks,
            onChanged: preferencesNotifier.setHandleSpotifyLinks,
          ),
        ),
        ListTile(
          leading: const Icon(SpotubeIcons.magic),
          title: const Text("Experimental scoring"),
          subtitle: const Text(
            "Prefer music-only YouTube matches over music videos when resolving tracks",
          ),
          trailing: Switch(
            value: preferences.experimentalScoring,
            onChanged: preferencesNotifier.setExperimentalScoring,
          ),
        ),
        ListTile(
          leading: const Icon(SpotubeIcons.playlistRemove),
          title: Text(context.l10n.blacklist),
          subtitle: Text(context.l10n.blacklist_description),
          onTap: () {
            context.navigateTo(const BlackListRoute());
          },
          trailing: const Icon(SpotubeIcons.angleRight),
        ),
        ListTile(
          leading: const Icon(SpotubeIcons.normalize),
          title: Text(context.l10n.normalize_audio),
          trailing: Switch(
            value: preferences.normalizeAudio,
            onChanged: preferencesNotifier.setNormalizeAudio,
          ),
        ),
        ListTile(
            leading: const Icon(SpotubeIcons.repeat),
            title: Text(context.l10n.endless_playback),
            trailing: Switch(
              value: preferences.endlessPlayback,
              onChanged: preferencesNotifier.setEndlessPlayback,
            )),
        ListTile(
          leading: const Icon(SpotubeIcons.history),
          title: const Text("Resume last song on launch"),
          subtitle: const Text(
            "Restore the last track and playback position when the app opens",
          ),
          trailing: Switch(
            value: preferences.resumePlaybackOnLaunch,
            onChanged: preferencesNotifier.setResumePlaybackOnLaunch,
          ),
        ),
        ListTile(
          leading: const Icon(SpotubeIcons.stream),
          title: const Text("Crossfade tracks"),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Fade out the current track and fade in the next one",
                ),
                const Gap(8),
                Opacity(
                  opacity: preferences.crossfadeTracks ? 1 : 0.5,
                  child: IgnorePointer(
                    ignoring: !preferences.crossfadeTracks,
                    child: Row(
                      spacing: 12,
                      children: [
                        Expanded(
                          child: Slider(
                            value: SliderValue.single(
                              (preferences.crossfadeDurationSeconds - 1) / 14,
                            ),
                            onChanged: (value) {
                              preferencesNotifier.setCrossfadeDurationSeconds(
                                1 + (value.value * 14).round(),
                              );
                            },
                          ),
                        ),
                        SizedBox(
                          width: 36,
                          child: Text(
                            "${preferences.crossfadeDurationSeconds}s",
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          trailing: Switch(
            value: preferences.crossfadeTracks,
            onChanged: preferencesNotifier.setCrossfadeTracks,
          ),
        ),
        ListTile(
          title: Text(context.l10n.enable_connect),
          subtitle: Text(context.l10n.enable_connect_description),
          leading: const Icon(SpotubeIcons.connect),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 10,
            children: [
              Tooltip(
                tooltip: TooltipContainer(
                  child: Text(context.l10n.edit_port),
                ).call,
                child: IconButton.outline(
                  icon: const Icon(SpotubeIcons.edit),
                  size: ButtonSize.small,
                  onPressed: () {
                    showDialog(
                      context: context,
                      barrierColor: Colors.black.withValues(alpha: 0.5),
                      builder: (context) =>
                          const SettingsPlaybackEditConnectPortDialog(),
                    );
                  },
                ),
              ),
              Switch(
                value: preferences.enableConnect,
                onChanged: preferencesNotifier.setEnableConnect,
              ),
            ],
          ),
        ),
        ListTile(
          leading: const Icon(SpotubeIcons.web),
          title: const Text("Multi-Session relay"),
          subtitle: Text(relaySubtitle),
          onTap: () async {
            final controller = TextEditingController(
              text: relayUrl == _legacyRelayUrl
                  ? ""
                  : preferences.multiSessionRelayUrl,
            );
            final value = await showDialog<String>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text("Multi-Session relay"),
                content: TextField(controller: controller),
                actions: [
                  Button.secondary(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(context.l10n.cancel),
                  ),
                  Button.primary(
                    onPressed: () =>
                        Navigator.of(context).pop(controller.text.trim()),
                    child: Text(context.l10n.save),
                  ),
                ],
              ),
            );
            if (value == null) return;
            preferencesNotifier.setMultiSessionRelayUrl(value);
          },
        ),
      ],
    );
  }
}
