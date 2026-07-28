import 'package:flutter/material.dart' as material;
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/modules/settings/youtube_engine_not_installed_dialog.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/youtube_engine/android_yt_dlp_engine.dart';
import 'package:spotube/services/youtube_engine/yt_dlp_binary.dart';
import 'package:spotube/utils/platform.dart';

class EnginePriorityDialog extends HookConsumerWidget {
  const EnginePriorityDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferences = ref.watch(userPreferencesProvider);
    final preferencesNotifier = ref.watch(userPreferencesProvider.notifier);

    final enginesState = useState<List<YoutubeClientEngine>>(
      preferences.youtubeClientEngines.toList(),
    );

    final availableEngines = YoutubeClientEngine.values
        .where((e) => e.isAvailableForPlatform())
        .toList();

    // Sort so that enabled ones are first (in their current order), followed by disabled ones.
    final orderedEngines = [
      ...enginesState.value.where((e) => availableEngines.contains(e)),
      ...availableEngines.where((e) => !enginesState.value.contains(e)),
    ];

    return AlertDialog(
      title: const Text('YouTube Engine Priority'),
      content: SizedBox(
        width: 400,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final itemCount = orderedEngines.length;
            final contentHeight =
                (itemCount * 72.0).clamp(200.0, constraints.maxHeight * 0.7);
            return SizedBox(
              height: contentHeight,
              child: material.Material(
                color: material.Colors.transparent,
                child: material.ReorderableListView(
                  buildDefaultDragHandles: false,
                  onReorder: (oldIndex, newIndex) {
                    if (oldIndex < newIndex) newIndex -= 1;
                    final list = orderedEngines.toList();
                    final item = list.removeAt(oldIndex);
                    list.insert(newIndex, item);
                    enginesState.value =
                        list.where((e) => enginesState.value.contains(e)).toList();
                  },
                  children: [
                    for (int i = 0; i < orderedEngines.length; i++)
                      material.ReorderableDragStartListener(
                        key: ValueKey(orderedEngines[i]),
                        index: i,
                        child: material.ListTile(
                          title: Text(orderedEngines[i].label),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: enginesState.value.contains(orderedEngines[i]),
                                onChanged: (val) async {
                                  final list = enginesState.value.toList();
                                  if (val) {
                                    if (orderedEngines[i] == YoutubeClientEngine.ytDlp) {
                                      final isInstalled = kIsAndroid
                                          ? await AndroidYtDlpEngine.isInstalled()
                                          : await YtDlpBinary.ensureAvailable(
                                              downloadIfMissing: false);
                                      if (!isInstalled && context.mounted) {
                                        final hasInstalled = await showDialog<bool>(
                                          context: context,
                                          builder: (context) =>
                                              YouTubeEngineNotInstalledDialog(
                                                  engine: orderedEngines[i]),
                                        );
                                        if (hasInstalled != true) return;
                                      }
                                    }
                                    list.add(orderedEngines[i]);
                                  } else {
                                    list.remove(orderedEngines[i]);
                                  }
                                  enginesState.value = list;
                                },
                              ),
                              const Gap(16),
                              const Icon(material.Icons.drag_handle),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        Button.secondary(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.cancel),
        ),
        Button.primary(
          onPressed: () {
            preferencesNotifier.setYoutubeClientEngines(enginesState.value);
            Navigator.of(context).pop();
          },
          child: Text(context.l10n.save),
        ),
      ],
    );
  }
}
