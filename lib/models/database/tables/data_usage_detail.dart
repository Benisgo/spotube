part of '../database.dart';

class DataUsageDetailTable extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get date => dateTime()();
  TextColumn get trackId => text()();
  TextColumn get trackName => text()();
  TextColumn get trackArtist => text()();
  IntColumn get bytes => integer().withDefault(const Constant(0))();
}
