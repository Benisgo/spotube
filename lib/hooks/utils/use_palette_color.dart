import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

PaletteColor usePaletteColor(String imageUrl, WidgetRef ref) {
  final context = useContext();
  final theme = Theme.of(context);
  return useMemoized(
    () => PaletteColor(theme.colorScheme.card, 0),
    [theme.colorScheme.card],
  );
}

PaletteGenerator usePaletteGenerator(String imageUrl) {
  final context = useContext();
  final theme = Theme.of(context);
  return useMemoized(
    () => PaletteGenerator.fromColors([
      PaletteColor(theme.colorScheme.card, 0),
    ]),
    [theme.colorScheme.card],
  );
}
