import 'package:drift/drift.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/provider/database/database.dart';

/// Tracks total bytes streamed per day.
final dataUsageProvider = FutureProvider<Map<DateTime, int>>((ref) async {
  final db = ref.read(databaseProvider);
  final rows = await db.select(db.dataUsageTable).get();
  final map = <DateTime, int>{};
  for (final row in rows) {
    final day = DateTime(row.date.year, row.date.month, row.date.day);
    map[day] = (map[day] ?? 0) + row.bytes;
  }
  return map;
});

/// Per-song data usage grouped by date.
final dataUsageDetailProvider =
    FutureProvider<Map<DateTime, List<TrackUsage>>>((ref) async {
  final db = ref.read(databaseProvider);
  final rows = await db.select(db.dataUsageDetailTable).get();
  final map = <DateTime, List<TrackUsage>>{};
  for (final row in rows) {
    final day = DateTime(row.date.year, row.date.month, row.date.day);
    map.putIfAbsent(day, () => []).add(TrackUsage(
          trackId: row.trackId,
          trackName: row.trackName,
          trackArtist: row.trackArtist,
          bytes: row.bytes,
        ));
  }
  return map;
});

/// Usage details for a specific day.
final dataUsageForDayProvider =
    FutureProvider.family<List<TrackUsage>, DateTime>((ref, day) async {
  final all = await ref.watch(dataUsageDetailProvider.future);
  return all[day] ?? [];
});

/// Returns total bytes for the current month.
final dataUsageThisMonthProvider = FutureProvider<int>((ref) async {
  final data = await ref.watch(dataUsageProvider.future);
  final now = DateTime.now();
  final startOfMonth = DateTime(now.year, now.month, 1);
  int total = 0;
  for (final entry in data.entries) {
    if (entry.key.isAfter(startOfMonth) ||
        entry.key.isAtSameMomentAs(startOfMonth)) {
      total += entry.value;
    }
  }
  return total;
});

class TrackUsage {
  final String trackId;
  final String trackName;
  final String trackArtist;
  final int bytes;
  const TrackUsage({
    required this.trackId,
    required this.trackName,
    required this.trackArtist,
    required this.bytes,
  });
}

/// Record bytes streamed for today.
Future<void> recordDataUsage(Ref ref, int bytes,
    {String? trackId, String? trackName, String? trackArtist}) async {
  if (bytes <= 0) return;
  final db = ref.read(databaseProvider);
  final today = DateTime.now();
  final startOfDay = DateTime(today.year, today.month, today.day);

  // Update daily total
  final existing = await (db.select(db.dataUsageTable)
        ..where((t) => t.date.equals(startOfDay)))
      .get()
      .then((r) => r.isNotEmpty ? r.first : null);

  if (existing != null) {
    await (db.update(db.dataUsageTable)..where((t) => t.id.equals(existing.id)))
        .write(DataUsageTableCompanion(
      bytes: Value(existing.bytes + bytes),
    ));
  } else {
    await db.into(db.dataUsageTable).insert(
          DataUsageTableCompanion.insert(
            date: startOfDay,
            bytes: Value(bytes),
          ),
        );
  }

  // Track per-song usage if we have track info.
  // UPSERT per (trackId + day): accumulate bytes into a single row
  // instead of inserting a new row per call. Otherwise the same track
  // shows up dozens of times in the stats (per chunk) — see Bug: data
  // usage duplication.
  if (trackId != null && trackName != null) {
    final existingDetail = await (db.select(db.dataUsageDetailTable)
          ..where((t) => t.trackId.equals(trackId) & t.date.equals(startOfDay)))
        .get()
        .then((r) => r.isNotEmpty ? r.first : null);

    if (existingDetail != null) {
      await (db.update(db.dataUsageDetailTable)
            ..where((t) => t.id.equals(existingDetail.id)))
          .write(DataUsageDetailTableCompanion(
        bytes: Value(existingDetail.bytes + bytes),
      ));
    } else {
      await db.into(db.dataUsageDetailTable).insert(
            DataUsageDetailTableCompanion.insert(
              date: startOfDay,
              trackId: trackId,
              trackName: trackName,
              trackArtist: trackArtist ?? '',
              bytes: Value(bytes),
            ),
          );
    }
  }

  ref.invalidate(dataUsageProvider);
  ref.invalidate(dataUsageDetailProvider);
}

/// Clear all data usage records.
Future<void> clearDataUsage() async {
  final db = AppDatabase.current;
  if (db == null) return;
  await db.delete(db.dataUsageTable).go();
  await db.delete(db.dataUsageDetailTable).go();
}
