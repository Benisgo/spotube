part of '../database.dart';

class DataUsageTable extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get date => dateTime()();
  IntColumn get bytes => integer().withDefault(const Constant(0))();
}
