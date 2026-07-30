library database;

import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:drift/remote.dart';
import 'package:encrypt/encrypt.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' show ThemeMode, Colors;
import 'package:spotube/models/database/database.steps.dart';
import 'package:spotube/models/lyrics.dart';
import 'package:spotube/models/metadata/market.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/services/kv_store/encrypted_kv_store.dart';
import 'package:spotube/services/kv_store/kv_store.dart';
import 'package:flutter/widgets.dart' hide Table, Key, View;
import 'package:spotube/modules/settings/color_scheme_picker_dialog.dart';
import 'package:drift/native.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/youtube_engine/newpipe_engine.dart';
import 'package:spotube/services/youtube_engine/android_yt_dlp_engine.dart';
import 'package:spotube/services/youtube_engine/innertube_engine.dart';
import 'package:spotube/services/youtube_engine/youtube_explode_engine.dart';
import 'package:spotube/services/youtube_engine/yt_dlp_engine.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';

part 'database.g.dart';

part 'tables/authentication.dart';
part 'tables/blacklist.dart';
part 'tables/preferences.dart';
part 'tables/scrobbler.dart';
part 'tables/skip_segment.dart';
part 'tables/source_match.dart';
part 'tables/audio_player_state.dart';
part 'tables/data_usage.dart';
part 'tables/data_usage_detail.dart';
part 'tables/history.dart';
part 'tables/lyrics.dart';
part 'tables/metadata_plugins.dart';

part 'typeconverters/color.dart';
part 'typeconverters/locale.dart';
part 'typeconverters/string_list.dart';
part 'typeconverters/encrypted_text.dart';
part 'typeconverters/map.dart';
part 'typeconverters/map_list.dart';
part 'typeconverters/subtitle.dart';

@DriftDatabase(
  tables: [
    AuthenticationTable,
    BlacklistTable,
    PreferencesTable,
    ScrobblerTable,
    SkipSegmentTable,
    SourceMatchTable,
    AudioPlayerStateTable,
    DataUsageTable,
    DataUsageDetailTable,
    HistoryTable,
    LyricsTable,
    PluginsTable,
  ],
)
class AppDatabase extends _$AppDatabase {
  static AppDatabase? current;

  AppDatabase() : super(_openConnection()) {
    current = this;
  }
  AppDatabase.withExecutor(super.e) {
    current = this;
  }

  @override
  int get schemaVersion => 20;

  @override
  MigrationStrategy get migration {
    final migrateToV10 = stepByStep(
      from1To2: (m, schema) async {
        // Add invidiousInstance column to preferences table
        await m.addColumn(
          schema.preferencesTable,
          schema.preferencesTable.invidiousInstance,
        );
      },
      from2To3: (m, schema) async {
        await m.addColumn(
          schema.preferencesTable,
          schema.preferencesTable.cacheMusic,
        );
      },
      from3To4: (m, schema) async {
        await m.addColumn(
          schema.preferencesTable,
          schema.preferencesTable.youtubeClientEngine,
        );
      },
      from4To5: (m, schema) async {
        final columnName =
            schema.preferencesTable.accentColorScheme.escapedNameFor(
          SqlDialect.sqlite,
        );
        final columnNameOld =
            '"${schema.preferencesTable.accentColorScheme.name}_old"';
        final tableName = schema.preferencesTable.actualTableName;
        await customStatement(
          "ALTER TABLE $tableName "
          "RENAME COLUMN $columnName to $columnNameOld",
        );
        await customStatement(
          "ALTER TABLE $tableName "
          "ADD COLUMN $columnName TEXT NOT NULL DEFAULT 'Slate:0xff64748b'",
        );
        await customStatement(
          "UPDATE $tableName "
          "SET $columnName = $columnNameOld",
        );
        await customStatement(
          "ALTER TABLE $tableName "
          "DROP COLUMN $columnNameOld",
        );
        await customStatement(
          "UPDATE $tableName "
          "SET $columnName = 'Slate:0xff64748b' WHERE $columnName = 'Blue:0xFF2196F3'",
        );
      },
      from5To6: (m, schema) async {
        try {
          await m.addColumn(
            schema.preferencesTable,
            schema.preferencesTable.connectPort,
          );
        } on DriftRemoteException catch (e) {
          // If the column already exists, ignore the error
          if (e.remoteCause !=
              'duplicate column name: ${schema.preferencesTable.connectPort.name}') {
            rethrow;
          }
        }
      },
      from6To7: (m, schema) async {
        await m.createTable(schema.metadataPluginsTable);
        await m.addColumn(
          schema.audioPlayerStateTable,
          schema.audioPlayerStateTable.currentIndex,
        );
        await m.addColumn(
          schema.audioPlayerStateTable,
          schema.audioPlayerStateTable.tracks,
        );
      },
      from7To8: (m, schema) async {
        await m
            .addColumn(
          schema.metadataPluginsTable,
          schema.metadataPluginsTable.entryPoint,
        )
            .catchError((error, stackTrace) {
          // If the column already exists, ignore the error
          if (!error.toString().contains('duplicate column name')) {
            throw error;
          }
        });
        await m
            .addColumn(
          schema.metadataPluginsTable,
          schema.metadataPluginsTable.apis,
        )
            .catchError((error, stackTrace) {
          // If the column already exists, ignore the error
          if (!error.toString().contains('duplicate column name')) {
            throw error;
          }
        });
        await m
            .addColumn(
          schema.metadataPluginsTable,
          schema.metadataPluginsTable.abilities,
        )
            .catchError((error, stackTrace) {
          // If the column already exists, ignore the error
          if (!error.toString().contains('duplicate column name')) {
            throw error;
          }
        });
        await m
            .addColumn(
          schema.metadataPluginsTable,
          schema.metadataPluginsTable.repository,
        )
            .catchError((error, stackTrace) {
          // If the column already exists, ignore the error
          if (!error.toString().contains('duplicate column name')) {
            throw error;
          }
        });
        await m
            .addColumn(
          schema.metadataPluginsTable,
          schema.metadataPluginsTable.pluginApiVersion,
        )
            .catchError((error, stackTrace) {
          // If the column already exists, ignore the error
          if (!error.toString().contains('duplicate column name')) {
            throw error;
          }
        });
      },
      from8To9: (m, schema) async {
        await m
            .renameTable(schema.pluginsTable, "metadata_plugins_table")
            .catchError((e, stack) => AppLogger.reportError(e, stack));
        await m
            .renameColumn(
              schema.pluginsTable,
              "selected",
              pluginsTable.selectedForMetadata,
            )
            .catchError((e, stack) => AppLogger.reportError(e, stack));
        await m
            .addColumn(
              schema.pluginsTable,
              pluginsTable.selectedForAudioSource,
            )
            .catchError((e, stack) => AppLogger.reportError(e, stack));
      },
      from9To10: (m, schema) async {
        await m
            .dropColumn(schema.preferencesTable, "piped_instance")
            .catchError((e, stack) => AppLogger.reportError(e, stack));
        await m
            .dropColumn(schema.preferencesTable, "invidious_instance")
            .catchError((e, stack) => AppLogger.reportError(e, stack));
        await m
            .addColumn(
              schema.sourceMatchTable,
              sourceMatchTable.sourceInfo,
            )
            .catchError((e, stack) => AppLogger.reportError(e, stack));
        await customStatement("DROP INDEX IF EXISTS uniq_track_match;")
            .catchError((e, stack) => AppLogger.reportError(e, stack));
        await m
            .dropColumn(schema.sourceMatchTable, "source_id")
            .catchError((e, stack) => AppLogger.reportError(e, stack));
      },
    );

    return MigrationStrategy(
      onUpgrade: (m, from, to) async {
        final targetV10 = to > 10 ? 10 : to;

        if (from < targetV10) {
          await migrateToV10(m, from, targetV10);
        }
        if (from < 11 && to >= 11) {
          await customStatement(
            "ALTER TABLE preferences_table "
            "ADD COLUMN lyrics_character_edge TEXT NOT NULL DEFAULT '${LyricsCharacterEdge.none.name}'",
          ).catchError((error, stackTrace) {
            if (!error.toString().contains('duplicate column name')) {
              throw error;
            }
          });
          await customStatement(
            "ALTER TABLE preferences_table "
            "ADD COLUMN multi_session_relay_url TEXT NOT NULL DEFAULT ''",
          ).catchError((error, stackTrace) {
            if (!error.toString().contains('duplicate column name')) {
              throw error;
            }
          });
        }
        if (from < 12 && to >= 12) {
          await customStatement(
            "ALTER TABLE preferences_table "
            "ADD COLUMN mini_player_transparency REAL NOT NULL DEFAULT 0.55",
          ).catchError((error, stackTrace) {
            if (!error.toString().contains('duplicate column name')) {
              throw error;
            }
          });
        }
        if (from < 13 && to >= 13) {
          await customStatement(
            "ALTER TABLE preferences_table "
            "ADD COLUMN resume_playback_on_launch INTEGER NOT NULL DEFAULT 0",
          ).catchError((error, stackTrace) {
            if (!error.toString().contains('duplicate column name')) {
              throw error;
            }
          });
          await customStatement(
            "ALTER TABLE audio_player_state_table "
            "ADD COLUMN position_ms INTEGER NOT NULL DEFAULT 0",
          ).catchError((error, stackTrace) {
            if (!error.toString().contains('duplicate column name')) {
              throw error;
            }
          });
        }
        if (from < 14 && to >= 14) {
          await customStatement(
            "ALTER TABLE preferences_table "
            "ADD COLUMN crossfade_tracks INTEGER NOT NULL DEFAULT 0",
          ).catchError((error, stackTrace) {
            if (!error.toString().contains('duplicate column name')) {
              throw error;
            }
          });
          await customStatement(
            "ALTER TABLE preferences_table "
            "ADD COLUMN crossfade_duration_seconds INTEGER NOT NULL DEFAULT 5",
          ).catchError((error, stackTrace) {
            if (!error.toString().contains('duplicate column name')) {
              throw error;
            }
          });
        }
        if (from < 15 && to >= 15) {
          await customStatement(
            "ALTER TABLE preferences_table "
            "ADD COLUMN experimental_scoring INTEGER NOT NULL DEFAULT 0",
          ).catchError((error, stackTrace) {
            if (!error.toString().contains('duplicate column name')) {
              throw error;
            }
          });
        }
        if (from < 16 && to >= 16) {
          await customStatement(
            "ALTER TABLE preferences_table "
            "ADD COLUMN handle_spotify_links INTEGER NOT NULL DEFAULT 1",
          ).catchError((error, stackTrace) {
            if (!error.toString().contains('duplicate column name')) {
              throw error;
            }
          });
        }
        if (from < 17 && to >= 17) {
          await customStatement(
            "ALTER TABLE preferences_table "
            "ADD COLUMN youtube_client_engines TEXT NOT NULL DEFAULT '[]'",
          ).catchError((error, stackTrace) {
            if (!error.toString().contains('duplicate column name')) {
              throw error;
            }
          });
        }
        if (from < 18 && to >= 18) {
          await customStatement(
            "ALTER TABLE preferences_table "
            "ADD COLUMN enable_fast_playback INTEGER NOT NULL DEFAULT 0",
          ).catchError((error, stackTrace) {
            if (!error.toString().contains('duplicate column name')) {
              throw error;
            }
          });
        }
        if (from < 19 && to >= 19) {
          await customStatement("CREATE TABLE IF NOT EXISTS data_usage_table ("
                  "id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "
                  "date INTEGER NOT NULL, "
                  "bytes INTEGER NOT NULL DEFAULT 0)")
              .catchError((e, stack) {
            AppLogger.reportError(e, stack);
          });
        }
        if (from < 20 && to >= 20) {
          await customStatement(
                  "CREATE TABLE IF NOT EXISTS data_usage_detail_table ("
                  "id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "
                  "date INTEGER NOT NULL, "
                  "track_id TEXT NOT NULL, "
                  "track_name TEXT NOT NULL, "
                  "track_artist TEXT NOT NULL, "
                  "bytes INTEGER NOT NULL DEFAULT 0)")
              .catchError((e, stack) {
            AppLogger.reportError(e, stack);
          });
        }
      },
    );
  }
}

LazyDatabase _openConnection() {
  // the LazyDatabase util lets us find the right location for the file async.
  return LazyDatabase(() async {
    // put the database file, called db.sqlite here, into the documents folder
    // for your app.
    final dbFolder = await getApplicationSupportDirectory();
    final file = File(join(dbFolder.path, 'db.sqlite'));

    // Also work around limitations on old Android versions
    if (Platform.isAndroid) {
      await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();
    }

    // Make sqlite3 pick a more suitable location for temporary files - the
    // one from the system may be inaccessible due to sandboxing.
    final cacheBase = (await getTemporaryDirectory()).path;
    // We can't access /tmp on Android, which sqlite3 would try by default.
    // Explicitly tell it about the correct temporary directory.
    sqlite3.tempDirectory = cacheBase;

    return NativeDatabase.createInBackground(file);
  });
}
