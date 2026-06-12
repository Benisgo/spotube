part of '../database.dart';

enum LayoutMode {
  compact,
  extended,
  adaptive,
}

enum CloseBehavior {
  minimizeToTray,
  close,
}

enum YoutubeClientEngine {
  ytDlp("yt-dlp"),
  youtubeExplode("YouTubeExplode"),
  newPipe("NewPipe"),
  invidious("Invidious"),
  verome("Verome");

  final String label;

  const YoutubeClientEngine(this.label);

  bool isAvailableForPlatform() {
    return switch (this) {
      YoutubeClientEngine.youtubeExplode =>
        YouTubeExplodeEngine.isAvailableForPlatform,
      YoutubeClientEngine.ytDlp => YtDlpEngine.isAvailableForPlatform ||
          AndroidYtDlpEngine.isAvailableForPlatform,
      YoutubeClientEngine.newPipe => NewPipeEngine.isAvailableForPlatform,
      YoutubeClientEngine.invidious => InvidiousEngine.isAvailableForPlatform,
      YoutubeClientEngine.verome => VeromeEngine.isAvailableForPlatform,
    };
  }
}

enum LyricsCharacterEdge {
  none("None"),
  raised("Raised"),
  depressed("Depressed"),
  outline("Outline"),
  dropShadow("Drop shadow");

  final String label;

  const LyricsCharacterEdge(this.label);
}

enum SearchMode {
  youtube._("YouTube"),
  youtubeMusic._("YouTube Music");

  final String label;

  const SearchMode._(this.label);

  factory SearchMode.fromString(String key) {
    return SearchMode.values.firstWhere((e) => e.name == key);
  }
}

class YoutubeClientEnginesConverter
    extends TypeConverter<List<YoutubeClientEngine>, String> {
  const YoutubeClientEnginesConverter();

  @override
  List<YoutubeClientEngine> fromSql(String fromDb) {
    try {
      final List<dynamic> list = jsonDecode(fromDb);
      return list
          .map((e) =>
              YoutubeClientEngine.values.firstWhereOrNull((v) => v.name == e))
          .nonNulls
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  String toSql(List<YoutubeClientEngine> value) {
    return jsonEncode(value.map((e) => e.name).toList());
  }
}

class PreferencesTable extends Table {
  IntColumn get id => integer().autoIncrement()();
  BoolColumn get albumColorSync =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get amoledDarkTheme =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get checkUpdate => boolean().withDefault(const Constant(true))();
  BoolColumn get normalizeAudio =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get showSystemTrayIcon =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get systemTitleBar =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get skipNonMusic => boolean().withDefault(const Constant(false))();
  TextColumn get closeBehavior => textEnum<CloseBehavior>()
      .withDefault(Constant(CloseBehavior.close.name))();
  TextColumn get accentColorScheme => text()
      .withDefault(const Constant("Slate:0xff64748b"))
      .map(const SpotubeColorConverter())();
  TextColumn get layoutMode =>
      textEnum<LayoutMode>().withDefault(Constant(LayoutMode.adaptive.name))();
  TextColumn get locale => text()
      .withDefault(
        const Constant('{"languageCode":"system","countryCode":"system"}'),
      )
      .map(const LocaleConverter())();
  TextColumn get market =>
      textEnum<Market>().withDefault(Constant(Market.US.name))();
  TextColumn get searchMode =>
      textEnum<SearchMode>().withDefault(Constant(SearchMode.youtube.name))();
  TextColumn get downloadLocation => text().withDefault(const Constant(""))();
  TextColumn get localLibraryLocation =>
      text().withDefault(const Constant("")).map(const StringListConverter())();
  TextColumn get themeMode =>
      textEnum<ThemeMode>().withDefault(Constant(ThemeMode.system.name))();
  TextColumn get audioSourceId => text().nullable()();
  TextColumn get youtubeClientEngine => textEnum<YoutubeClientEngine>()
      .withDefault(Constant(YoutubeClientEngine.youtubeExplode.name))();
  TextColumn get youtubeClientEngines => text()
      .map(const YoutubeClientEnginesConverter())
      .withDefault(const Constant('[]'))();
  BoolColumn get discordPresence =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get endlessPlayback =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get enableConnect =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get resumePlaybackOnLaunch =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get crossfadeTracks =>
      boolean().withDefault(const Constant(false))();
  IntColumn get crossfadeDurationSeconds =>
      integer().withDefault(const Constant(5))();
  IntColumn get connectPort => integer().withDefault(const Constant(-1))();
  BoolColumn get cacheMusic => boolean().withDefault(const Constant(true))();
  BoolColumn get experimentalScoring =>
      boolean().withDefault(const Constant(false))();
  RealColumn get miniPlayerTransparency =>
      real().withDefault(const Constant(0.55))();
  TextColumn get lyricsCharacterEdge => textEnum<LyricsCharacterEdge>()
      .withDefault(Constant(LyricsCharacterEdge.none.name))();
  TextColumn get multiSessionRelayUrl =>
      text().withDefault(const Constant(""))();
  BoolColumn get handleSpotifyLinks =>
      boolean().withDefault(const Constant(true))();

  // Default values as PreferencesTableData
  static PreferencesTableData defaults() {
    return PreferencesTableData(
      id: 0,
      albumColorSync: true,
      amoledDarkTheme: false,
      checkUpdate: true,
      normalizeAudio: false,
      showSystemTrayIcon: false,
      systemTitleBar: false,
      skipNonMusic: false,
      closeBehavior: CloseBehavior.close,
      accentColorScheme: SpotubeColor(Colors.slate.value, name: "Slate"),
      layoutMode: LayoutMode.adaptive,
      locale: const Locale("system", "system"),
      market: Market.US,
      searchMode: SearchMode.youtube,
      downloadLocation: "",
      localLibraryLocation: [],
      themeMode: ThemeMode.system,
      audioSourceId: null,
      youtubeClientEngine: YoutubeClientEngine.invidious,
      youtubeClientEngines: [
        YoutubeClientEngine.invidious,
        YoutubeClientEngine.ytDlp,
        YoutubeClientEngine.verome,
        YoutubeClientEngine.newPipe,
      ],
      discordPresence: true,
      endlessPlayback: true,
      enableConnect: false,
      resumePlaybackOnLaunch: false,
      crossfadeTracks: false,
      crossfadeDurationSeconds: 5,
      cacheMusic: true,
      experimentalScoring: false,
      miniPlayerTransparency: 0.55,
      connectPort: -1,
      lyricsCharacterEdge: LyricsCharacterEdge.none,
      multiSessionRelayUrl: "",
      handleSpotifyLinks: true,
    );
  }
}
