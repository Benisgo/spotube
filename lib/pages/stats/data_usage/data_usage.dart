import 'package:fl_chart/fl_chart.dart' as fl;
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:spotube/collections/assets.gen.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/components/image/universal_image.dart';
import 'package:spotube/components/titlebar/titlebar.dart';

import 'package:spotube/provider/data_usage/data_usage_provider.dart';
import 'package:auto_route/auto_route.dart';

@RoutePage()
class StatsDataUsagePage extends HookConsumerWidget {
  const StatsDataUsagePage({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final refreshToggle = useState(0);
    final dailyData = ref.watch(dataUsageProvider).valueOrNull ?? {};
    final allDetails = ref.watch(dataUsageDetailProvider).valueOrNull ?? {};
    final selectedDay = useState<DateTime?>(null);
    final dayDetails = selectedDay.value != null
        ? (allDetails[selectedDay.value!] ?? <TrackUsage>[])
        : <TrackUsage>[];

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final last30 =
        List.generate(30, (i) => today.subtract(Duration(days: 29 - i)));
    final maxBytes = last30.fold<int>(0, (max, d) {
      final v = dailyData[d] ?? 0;
      return v > max ? v : max;
    });

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return SafeArea(
      bottom: false,
      child: Scaffold(
        headers: const [
          TitleBar(title: Text("Data Usage")),
        ],
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
          children: [
            // ── Month total card ──
            SurfaceCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Icon(SpotubeIcons.barChart,
                      size: 40, color: theme.colorScheme.primary),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("This Month",
                            style: theme.typography.small.copyWith(
                                color: theme.colorScheme.foreground
                                    .withValues(alpha: 0.6))),
                        const SizedBox(height: 4),
                        Text(
                          _formatBytes(ref
                                  .watch(dataUsageThisMonthProvider)
                                  .valueOrNull ??
                              0),
                          style: theme.typography.h2,
                        ),
                      ],
                    ),
                  ),
                  Button(
                    style: ButtonVariance.secondary,
                    onPressed: () {
                      clearDataUsage().then((_) {
                        ref.invalidate(dataUsageProvider);
                        ref.invalidate(dataUsageDetailProvider);
                        refreshToggle.value++;
                      });
                    },
                    child: const Text("Clear"),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 16),

            // ── Bar chart ──
            SurfaceCard(
              padding: EdgeInsets.zero,
              child: SizedBox(
                height: 240,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
                  child: fl.BarChart(
                    fl.BarChartData(
                      alignment: fl.BarChartAlignment.spaceAround,
                      maxY: maxBytes > 0 ? maxBytes * 1.15 : 1,
                      barTouchData: fl.BarTouchData(
                        enabled: true,
                        touchTooltipData: fl.BarTouchTooltipData(
                          getTooltipColor: (_) => theme.colorScheme.foreground,
                          getTooltipItem: (group, groupIndex, rod, rodIndex) {
                            final day = last30[group.x.toInt()];
                            final bytes = dailyData[day] ?? 0;
                            return fl.BarTooltipItem(
                              "${day.day}/${day.month}\n${_formatBytes(bytes)}",
                              TextStyle(
                                color: theme.colorScheme.background,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            );
                          },
                        ),
                        touchCallback: (event, response) {
                          if (response?.spot != null &&
                              event is fl.FlTapUpEvent) {
                            final idx = response!.spot!.touchedBarGroupIndex;
                            if (idx >= 0 && idx < last30.length) {
                              selectedDay.value = last30[idx];
                            }
                          }
                        },
                      ),
                      titlesData: fl.FlTitlesData(
                        show: true,
                        topTitles: const fl.AxisTitles(
                            sideTitles: fl.SideTitles(showTitles: false)),
                        rightTitles: const fl.AxisTitles(
                            sideTitles: fl.SideTitles(showTitles: false)),
                        leftTitles: fl.AxisTitles(
                          sideTitles: fl.SideTitles(
                            showTitles: true,
                            reservedSize: 48,
                            getTitlesWidget: (value, meta) {
                              return fl.SideTitleWidget(
                                meta: meta,
                                child: Text(_formatBytes(value.toInt()),
                                    style: theme.typography.small
                                        .copyWith(fontSize: 10)),
                              );
                            },
                          ),
                        ),
                        bottomTitles: fl.AxisTitles(
                          sideTitles: fl.SideTitles(
                            showTitles: true,
                            reservedSize: 28,
                            interval: 4,
                            getTitlesWidget: (value, meta) {
                              final idx = value.toInt();
                              if (idx < 0 || idx >= last30.length) {
                                return const SizedBox.shrink();
                              }
                              final day = last30[idx];
                              final s = selectedDay.value == day;
                              return fl.SideTitleWidget(
                                meta: meta,
                                child: GestureDetector(
                                  onTap: () => selectedDay.value = day,
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 150),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: s
                                          ? theme.colorScheme.primary
                                              .withValues(alpha: 0.2)
                                          : null,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      "${day.day}",
                                      style: theme.typography.small.copyWith(
                                        fontWeight: s
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                        color: s
                                            ? theme.colorScheme.primary
                                            : theme.colorScheme.foreground
                                                .withValues(alpha: 0.7),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      borderData: fl.FlBorderData(show: false),
                      gridData: fl.FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: maxBytes > 0
                            ? (maxBytes / 4)
                                .ceilToDouble()
                                .clamp(1, double.infinity)
                            : 1,
                        getDrawingHorizontalLine: (value) {
                          return fl.FlLine(
                            color: theme.colorScheme.foreground
                                .withValues(alpha: 0.08),
                            strokeWidth: 1,
                          );
                        },
                      ),
                      barGroups: List.generate(last30.length, (i) {
                        final day = last30[i];
                        final bytes = dailyData[day] ?? 0;
                        final s = selectedDay.value == day;
                        return fl.BarChartGroupData(
                          x: i,
                          barRods: [
                            fl.BarChartRodData(
                              toY: bytes > 0 ? bytes.toDouble() : 0.5,
                              color: s
                                  ? theme.colorScheme.primary
                                  : (isDark
                                      ? theme.colorScheme.primary
                                          .withValues(alpha: 0.6)
                                      : theme.colorScheme.primary
                                          .withValues(alpha: 0.5)),
                              width: maxBytes > 0
                                  ? (240 / last30.length).clamp(4, 16)
                                  : 8,
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(3)),
                            ),
                          ],
                        );
                      }),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── Selected day header ──
            if (selectedDay.value != null) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "${selectedDay.value!.year}-${selectedDay.value!.month.toString().padLeft(2, '0')}-${selectedDay.value!.day.toString().padLeft(2, '0')}",
                    style: theme.typography.h3,
                  ),
                  Text(
                    _formatBytes(dailyData[selectedDay.value] ?? 0),
                    style: theme.typography.small.copyWith(
                        color: theme.colorScheme.foreground
                            .withValues(alpha: 0.6)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (dayDetails.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child:
                      Center(child: Text("No detailed data for this day yet.")),
                )
              else
                ...dayDetails.map((usage) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: SurfaceCard(
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: UniversalImage(
                                path: Assets.images.albumPlaceholder.path,
                                width: 44,
                                height: 44,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(usage.trackName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.typography.normal),
                                  Text(usage.trackArtist,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.typography.small.copyWith(
                                        color: theme.colorScheme.foreground
                                            .withValues(alpha: 0.6),
                                      )),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: Text(
                                _formatBytes(usage.bytes),
                                style: theme.typography.small.copyWith(
                                    color: theme.colorScheme.foreground
                                        .withValues(alpha: 0.6)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )),
            ],

            // ── No day selected hint ──
            if (selectedDay.value == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(
                  child: Text("Tap a bar or day number to view details"),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1073741824) {
      return "${(bytes / 1073741824).toStringAsFixed(1)} GB";
    } else if (bytes >= 1048576) {
      return "${(bytes / 1048576).toStringAsFixed(1)} MB";
    } else if (bytes >= 1024) {
      return "${(bytes / 1024).toStringAsFixed(0)} KB";
    }
    return "$bytes B";
  }
}
