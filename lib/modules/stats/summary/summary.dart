import 'package:auto_route/auto_route.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:spotube/collections/fake.dart';
import 'package:spotube/collections/formatters.dart';
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/modules/stats/summary/summary_card.dart';
import 'package:spotube/extensions/constrains.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/provider/data_usage/data_usage_provider.dart';
import 'package:spotube/provider/history/summary.dart';

class StatsPageSummarySection extends HookConsumerWidget {
  const StatsPageSummarySection({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final summary = ref.watch(playbackHistorySummaryProvider);
    final summaryData = summary.asData?.value ?? FakeData.historySummary;

    return Skeletonizer.sliver(
      enabled: summary.isLoading,
      child: SliverPadding(
        padding: const EdgeInsets.all(10),
        sliver: SliverLayoutBuilder(builder: (context, constrains) {
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: constrains.isXs
                  ? 2
                  : constrains.smAndDown
                      ? 3
                      : constrains.mdAndDown
                          ? 4
                          : constrains.lgAndDown
                              ? 5
                              : 6,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: constrains.isXs ? 1.3 : 1.5,
            ),
            delegate: SliverChildListDelegate([
              SummaryCard(
                title: summaryData.duration.inMinutes.toDouble(),
                unit: context.l10n.summary_minutes,
                description: context.l10n.summary_listened_to_music,
                color: Colors.indigo,
                onTap: () {
                  context.navigateTo(const StatsMinutesRoute());
                },
              ),
              SummaryCard(
                title: summaryData.tracks.toDouble(),
                unit: context.l10n.summary_songs,
                description: context.l10n.summary_streamed_overall,
                color: Colors.blue,
                onTap: () {
                  context.navigateTo(const StatsStreamsRoute());
                },
              ),
              SummaryCard.unformatted(
                title: usdFormatter.format(summaryData.fees.toDouble()),
                unit: "",
                description: context.l10n.summary_owed_to_artists,
                color: Colors.green,
                onTap: () {
                  context.navigateTo(const StatsStreamFeesRoute());
                },
              ),
              SummaryCard(
                title: summaryData.artists.toDouble(),
                unit: context.l10n.summary_artists,
                description: context.l10n.summary_music_reached_you,
                color: Colors.yellow,
                onTap: () {
                  context.navigateTo(const StatsArtistsRoute());
                },
              ),
              SummaryCard(
                title: summaryData.albums.toDouble(),
                unit: context.l10n.summary_full_albums,
                description: context.l10n.summary_got_your_love,
                color: Colors.pink,
                onTap: () {
                  context.navigateTo(const StatsAlbumsRoute());
                },
              ),
              SummaryCard(
                title: summaryData.playlists.toDouble(),
                unit: context.l10n.summary_playlists,
                description: context.l10n.summary_were_on_repeat,
                color: Colors.teal,
                onTap: () {
                  context.navigateTo(const StatsPlaylistsRoute());
                },
              ),
              SummaryCard.unformatted(
                title: _formatBytes(
                    ref.watch(dataUsageThisMonthProvider).valueOrNull ?? 0),
                unit: "",
                description: "Data streamed\nthis month",
                color: Colors.purple,
                onTap: () => _showDataUsageDialog(context, ref),
              ),
            ]),
          );
        }),
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

  Future<void> _showDataUsageDialog(BuildContext context, WidgetRef ref) async {
    final data = await ref.read(dataUsageProvider.future);

    if (!context.mounted) return;

    // Sort days descending
    final sorted = data.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Data Usage"),
        content: SizedBox(
          width: double.maxFinite,
          child: sorted.isEmpty
              ? const Text("No data usage recorded yet.")
              : ListBody(
                  children: [
                    ...sorted.take(30).map((entry) {
                      final dayStr =
                          "${entry.key.year}-${entry.key.month.toString().padLeft(2, '0')}-${entry.key.day.toString().padLeft(2, '0')}";
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(dayStr),
                            Text(_formatBytes(entry.value),
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                          ],
                        ),
                      );
                    }),
                    if (sorted.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: Text("Tap a song to start tracking data usage."),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              clearDataUsage(ref as Ref<Object?>);
            },
            child: const Text("Clear all data"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Close"),
          ),
        ],
      ),
    );
  }
}
