import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Compact count pill for sidebar footer buttons (Downloads / Devices /
/// Multi-Session). Rendered with explicit small dimensions so a single digit
/// (e.g. "1") never inherits odd sizing from the surrounding [Button] — a raw
/// shadcn [PrimaryBadge] nested inside a Button's trailing can get stretched /
/// vertical. Matches the look of a small primary badge.
class CountBadge extends StatelessWidget {
  final String count;
  const CountBadge(this.count, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        count,
        style: theme.typography.small.copyWith(
          color: theme.colorScheme.primaryForeground,
          fontWeight: FontWeight.w600,
          height: 1,
        ),
      ),
    );
  }
}
