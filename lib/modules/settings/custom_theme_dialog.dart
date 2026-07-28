import 'package:flutter/material.dart' as material;
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/models/theme/app_custom_theme.dart';
import 'package:spotube/provider/custom_theme/custom_theme_provider.dart';

class CustomThemeDialog extends HookConsumerWidget {
  const CustomThemeDialog({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final savedTheme = ref.watch(customThemeProvider);
    final notifier = ref.watch(customThemeProvider.notifier);
    final currentTheme = Theme.of(context);
    final currentScheme = currentTheme.colorScheme;
    final initialTheme = savedTheme.enabled
        ? savedTheme
        : savedTheme.copyWith(
            surfaceOpacity: currentTheme.surfaceOpacity ?? 0.8,
            surfaceBlur: currentTheme.surfaceBlur ?? 10,
            accentColor: currentScheme.primary,
            backgroundColor: currentScheme.background,
            foregroundColor: currentScheme.foreground,
            cardColor: currentScheme.card,
            cardForegroundColor: currentScheme.cardForeground,
            secondaryColor: currentScheme.secondary,
            mutedColor: currentScheme.muted,
            mutedForegroundColor: currentScheme.mutedForeground,
            borderColor: currentScheme.border,
          );
    final draft = useState(initialTheme);

    Widget buildColorField({
      required String label,
      required Color value,
      required ValueChanged<Color> onChanged,
    }) {
      return SizedBox(
        width: 220,
        child: material.Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label).semiBold(),
            const Gap(8),
            ColorInput(
              value: ColorDerivative.fromColor(value),
              initialMode: ColorPickerMode.hex,
              showAlpha: false,
              showHistory: false,
              onChanged: (color) => onChanged(color.toColor()),
            ),
          ],
        ),
      );
    }

    return AlertDialog(
      title: const Text("Custom theme").large(),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 500,
          maxHeight: MediaQuery.of(context).size.height * 0.65,
        ),
        child: SingleChildScrollView(
          child: material.Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              material.ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text("Enable custom theme"),
                subtitle: const Text(
                  "Override the app colors, blur, and transparency.",
                ),
                trailing: material.Switch(
                  value: draft.value.enabled,
                  onChanged: (value) {
                    draft.value = draft.value.copyWith(enabled: value);
                  },
                ),
              ),
              const Gap(12),
              material.ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text("Use current song cover as background"),
                subtitle: const Text(
                  "Show the active track artwork behind the app shell.",
                ),
                trailing: material.Switch(
                  value: draft.value.useNowPlayingCoverBackground,
                  onChanged: (value) {
                    draft.value = draft.value.copyWith(
                      useNowPlayingCoverBackground: value,
                    );
                  },
                ),
              ),
              const Gap(16),
              const Text("Surfaces").semiBold(),
              const Gap(8),
              Text(
                "Adjust the strength of cards, sheets, and translucent UI.",
                style: material.TextStyle(
                  color: currentScheme.mutedForeground,
                ),
              ),
              const Gap(12),
              _ThemeSlider(
                label: "Surface transparency",
                value: draft.value.surfaceOpacity,
                min: 0.0,
                max: 1.0,
                divisions: 20,
                trailing: "${(draft.value.surfaceOpacity * 100).round()}%",
                onChanged: (value) {
                  draft.value = draft.value.copyWith(surfaceOpacity: value);
                },
              ),
              const Gap(8),
              _ThemeSlider(
                label: "Surface blur",
                value: draft.value.surfaceBlur,
                min: 0,
                max: 40,
                divisions: 40,
                trailing: "${draft.value.surfaceBlur.round()} px",
                onChanged: (value) {
                  draft.value = draft.value.copyWith(surfaceBlur: value);
                },
              ),
              const Gap(8),
              _ThemeSlider(
                label: "Background cover opacity",
                value: draft.value.backgroundImageOpacity,
                min: 0.0,
                max: 1.0,
                divisions: 20,
                trailing:
                    "${(draft.value.backgroundImageOpacity * 100).round()}%",
                onChanged: (value) {
                  draft.value =
                      draft.value.copyWith(backgroundImageOpacity: value);
                },
              ),
              const Gap(8),
              _ThemeSlider(
                label: "Background cover blur",
                value: draft.value.backgroundImageBlur,
                min: 0,
                max: 50,
                divisions: 50,
                trailing: "${draft.value.backgroundImageBlur.round()} px",
                onChanged: (value) {
                  draft.value =
                      draft.value.copyWith(backgroundImageBlur: value);
                },
              ),
              const Gap(20),
              const Text("Theme colors").semiBold(),
              const Gap(8),
              Text(
                "Use the picker or a hex code for the core UI colors.",
                style: material.TextStyle(
                  color: currentScheme.mutedForeground,
                ),
              ),
              const Gap(12),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  buildColorField(
                    label: "Accent",
                    value: draft.value.accentColor,
                    onChanged: (color) {
                      draft.value = draft.value.copyWith(accentColor: color);
                    },
                  ),
                  buildColorField(
                    label: "Background",
                    value: draft.value.backgroundColor,
                    onChanged: (color) {
                      draft.value =
                          draft.value.copyWith(backgroundColor: color);
                    },
                  ),
                  buildColorField(
                    label: "Foreground",
                    value: draft.value.foregroundColor,
                    onChanged: (color) {
                      draft.value =
                          draft.value.copyWith(foregroundColor: color);
                    },
                  ),
                  buildColorField(
                    label: "Card",
                    value: draft.value.cardColor,
                    onChanged: (color) {
                      draft.value = draft.value.copyWith(cardColor: color);
                    },
                  ),
                  buildColorField(
                    label: "Card foreground",
                    value: draft.value.cardForegroundColor,
                    onChanged: (color) {
                      draft.value =
                          draft.value.copyWith(cardForegroundColor: color);
                    },
                  ),
                  buildColorField(
                    label: "Secondary",
                    value: draft.value.secondaryColor,
                    onChanged: (color) {
                      draft.value = draft.value.copyWith(secondaryColor: color);
                    },
                  ),
                  buildColorField(
                    label: "Muted",
                    value: draft.value.mutedColor,
                    onChanged: (color) {
                      draft.value = draft.value.copyWith(mutedColor: color);
                    },
                  ),
                  buildColorField(
                    label: "Muted foreground",
                    value: draft.value.mutedForegroundColor,
                    onChanged: (color) {
                      draft.value = draft.value.copyWith(
                        mutedForegroundColor: color,
                      );
                    },
                  ),
                  buildColorField(
                    label: "Border",
                    value: draft.value.borderColor,
                    onChanged: (color) {
                      draft.value = draft.value.copyWith(borderColor: color);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        Button.secondary(
          onPressed: () {
            draft.value = AppCustomTheme.defaults();
          },
          child: const Text("Reset"),
        ),
        Button.outline(
          child: Text(context.l10n.cancel),
          onPressed: () => Navigator.pop(context),
        ),
        Button.primary(
          child: Text(context.l10n.save),
          onPressed: () async {
            await notifier.setTheme(draft.value);
            if (context.mounted) {
              Navigator.pop(context);
            }
          },
        ),
      ],
    );
  }
}

class _ThemeSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String trailing;
  final ValueChanged<double> onChanged;

  const _ThemeSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.trailing,
    required this.onChanged,
    this.divisions,
  });

  @override
  Widget build(BuildContext context) {
    return material.Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        material.Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(
              trailing,
              style: material.TextStyle(
                color: Theme.of(context).colorScheme.mutedForeground,
              ),
            ),
          ],
        ),
        material.Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
