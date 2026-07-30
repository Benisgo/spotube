import 'package:drift/drift.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/provider/database/database.dart';

/// Tracks total bytes streamed per day, persisted in the database.
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

/// Record bytes streamed for today.
Future<void> recordDataUsage(Ref ref, int bytes) async {
  if (bytes <= 0) return;
  final db = ref.read(databaseProvider);
  final today = DateTime.now();
  final startOfDay = DateTime(today.year, today.month, today.day);

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
  ref.invalidate(dataUsageProvider);
}

/// Clear all data usage records.
Future<void> clearDataUsage(Ref<Object?> ref) async {
  final db = ref.read(databaseProvider);
  await db.delete(db.dataUsageTable).go();
  ref.invalidate(dataUsageProvider);
}
