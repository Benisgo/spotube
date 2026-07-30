import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/support.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/provider/metadata_plugin/tracks/track.dart';
import 'package:spotube/services/metadata/metadata.dart';
import 'package:spotube/services/sourced_track/sourced_track.dart';
import 'package:spotube/utils/spotify_link.dart';

class _ScoredResult {
  final SpotubeAudioSourceMatchObject match;
  int score = 0;
  final int index;
  final String title;
  final List<String> artists;
  final String durationStr;

  // Score breakdown fields (populated after scoring)
  int titleExact = 0;
  int titleCleanExact = 0;
  int titlePrefix = 0;
  int titleContains = 0;
  int titleTokenOverlap = 0;
  int wordOrderBonus = 0;
  int artistTokenOverlap = 0;
  int titleLengthPenalty = 0;
  int artistExactMatch = 0;
  int artistInTitle = 0;
  int noArtistPenalty = 0;
  int artistPrefixBonus = 0;
  int durationPoints = 0;
  int editionBonus = 0;
  int ytMusicBonus = 0;
  int officialAudioBonus = 0;
  int officialMusicBonus = 0;
  int audioBonus = 0;
  int featuredBonus = 0;
  int musicVideoPenalty = 0;
  int lyricVideoPenalty = 0;
  int livePenalty = 0;
  int remixPenalty = 0;

  _ScoredResult({
    required this.match,
    required this.score,
    required this.index,
    required this.title,
    required this.artists,
    required this.durationStr,
  });

  int get breakdownTotal =>
      titleExact +
      titleCleanExact +
      titlePrefix +
      titleContains +
      titleTokenOverlap +
      wordOrderBonus +
      artistTokenOverlap +
      titleLengthPenalty +
      artistExactMatch +
      artistInTitle +
      noArtistPenalty +
      artistPrefixBonus +
      durationPoints +
      editionBonus +
      ytMusicBonus +
      officialAudioBonus +
      officialMusicBonus +
      audioBonus +
      featuredBonus +
      musicVideoPenalty +
      lyricVideoPenalty +
      livePenalty +
      remixPenalty;
}

@RoutePage()
class DebugScoringTestPage extends HookConsumerWidget {
  const DebugScoringTestPage({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final trackNameC = useTextEditingController();
    final artistsC = useTextEditingController();
    final durationC = useTextEditingController(text: "30");
    final spotifyUrlC = useTextEditingController();

    final results = useState<List<_ScoredResult>>([]);
    final isSearching = useState(false);
    final resolving = useState(false);
    final statusMsg = useState<String?>(null);
    final resolvedTrack = useState<SpotubeFullTrackObject?>(null);

    // Auto-resolve Spotify URL
    useEffect(() {
      void onChanged() {
        final url = spotifyUrlC.text.trim();
        if (url.isEmpty) {
          resolvedTrack.value = null;
          return;
        }
        final parsed = parseSpotifyLink(url);
        if (parsed == null || parsed.type != SpotifyContentType.track) return;
        resolving.value = true;
        statusMsg.value = "Resolving Spotify track...";
        ref.read(metadataPluginTrackProvider(parsed.id).future).then((track) {
          trackNameC.text = track.name;
          artistsC.text = track.artists.map((a) => a.name).join(", ");
          durationC.text = (track.durationMs ~/ 1000).toString();
          resolvedTrack.value = track;
          statusMsg.value =
              "Resolved: ${track.name} — ${track.artists.map((a) => a.name).join(", ")}";
        }).catchError((e) {
          statusMsg.value = "Failed to resolve Spotify track: $e";
        }).whenComplete(() => resolving.value = false);
      }

      spotifyUrlC.addListener(onChanged);
      return () => spotifyUrlC.removeListener(onChanged);
    }, [spotifyUrlC]);

    Future<void> doSearch() async {
      // Use resolved track data if available, otherwise manual input
      final track = resolvedTrack.value;
      final name = track?.name ?? trackNameC.text.trim();
      final artistStr =
          track?.artists.map((a) => a.name).join(", ") ?? artistsC.text.trim();
      final durStr = track != null
          ? (track.durationMs ~/ 1000).toString()
          : durationC.text.trim();

      if (name.isEmpty) {
        statusMsg.value = resolvedTrack.value != null
            ? "Resolved track has no name"
            : "Enter a track name (or paste a Spotify URL)";
        return;
      }

      final artists = artistStr.isNotEmpty
          ? artistStr
              .split(",")
              .map((a) => a.trim())
              .where((a) => a.isNotEmpty)
              .toList()
          : <String>["Unknown Artist"];
      final durationSec = int.tryParse(durStr) ?? 30;

      isSearching.value = true;
      statusMsg.value = "Preparing search...";
      results.value = [];

      try {
        // Get the audio source plugin and search through it (same as engine)
        final audioSource = await ref.read(audioSourcePluginProvider.future);
        if (audioSource == null) {
          statusMsg.value = "No default audio source plugin configured";
          isSearching.value = false;
          return;
        }

        // Use resolved track or build mock
        final SpotubeFullTrackObject trackObj;
        if (track != null) {
          trackObj = track;
        } else {
          trackObj = SpotubeTrackObject.full(
            id: "debug",
            name: name,
            externalUri: "",
            artists: artists
                .map((a) =>
                    SpotubeSimpleArtistObject(id: "", name: a, externalUri: ""))
                .toList(),
            album: SpotubeSimpleAlbumObject(
              id: "",
              name: "",
              externalUri: "",
              artists: [],
              images: [],
              albumType: SpotubeAlbumType.album,
              releaseDate: "",
            ),
            durationMs: durationSec * 1000,
            isrc: "",
            explicit: false,
          ) as SpotubeFullTrackObject;
        }

        // Search using the actual audio source plugin (same as engine)
        statusMsg.value = "Searching via ${audioSource.slug}...";
        final searchResults = await audioSource.audioSource.matches(trackObj);

        if (searchResults.isEmpty) {
          statusMsg.value = "No results from audio source";
          isSearching.value = false;
          return;
        }

        statusMsg.value = "Found ${searchResults.length} results, scoring...";

        // Run experimental scoring (same function the engine uses)
        final ranked =
            SourcedTrack.rankResultsExperimental(searchResults, trackObj);

        // Build scored results with breakdown
        final scored = <_ScoredResult>[];
        for (int i = 0; i < ranked.length; i++) {
          final m = ranked[i];
          final r = _scoreBreakdown(m, trackObj);
          scored.add(r);
        }

        results.value = scored;
        statusMsg.value = "Scored ${scored.length} results";
      } catch (e) {
        statusMsg.value = "Error: $e";
      } finally {
        isSearching.value = false;
      }
    }

    // Build score breakdown text
    String _breakdownText(_ScoredResult r) {
      final parts = <String>[];
      void add(String label, int pts) {
        if (pts != 0) parts.add("$label${pts >= 0 ? '+' : ''}$pts");
      }

      add("Exact", r.titleExact);
      add("Clean", r.titleCleanExact);
      add("Prefix", r.titlePrefix);
      add("Contain", r.titleContains);
      add("Token", r.titleTokenOverlap);
      add("Order", r.wordOrderBonus);
      add("ArtTok", r.artistTokenOverlap);
      add("LenP", r.titleLengthPenalty);
      add("Art", r.artistExactMatch);
      add("ArtTit", r.artistInTitle);
      add("NoArt", r.noArtistPenalty);
      add("ArtPre", r.artistPrefixBonus);
      add("Dur", r.durationPoints);
      add("Ed", r.editionBonus);
      add("YT", r.ytMusicBonus);
      add("OffAud", r.officialAudioBonus);
      add("OffMus", r.officialMusicBonus);
      add("Aud", r.audioBonus);
      add("Feat", r.featuredBonus);
      add("MVid", r.musicVideoPenalty);
      add("Lyric", r.lyricVideoPenalty);
      add("Live", r.livePenalty);
      add("Remix", r.remixPenalty);
      return parts.join(" ");
    }

    return Scaffold(
      appBar: AppBar(title: const Text("Scoring Test")),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 160),
        children: [
          // Spotify URL field
          TextField(
            controller: spotifyUrlC,
            decoration: InputDecoration(
              labelText: "Spotify Track URL (auto-resolve)",
              hintText: "https://open.spotify.com/track/...",
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: resolving.value
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ))
                  : null,
            ),
          ),
          const SizedBox(height: 8),

          // Track name
          TextField(
            controller: trackNameC,
            decoration: const InputDecoration(
              labelText: "Track Name *",
              hintText: "e.g. Never Gonna Give You Up",
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),

          // Artists + Duration row
          Row(children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: artistsC,
                decoration: const InputDecoration(
                  labelText: "Artists (comma sep.)",
                  hintText: "Rick Astley",
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 1,
              child: TextField(
                controller: durationC,
                decoration: const InputDecoration(
                  labelText: "Dur (sec)",
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ]),
          const SizedBox(height: 12),

          // Search button
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: isSearching.value || resolving.value ? null : doSearch,
              icon: isSearching.value || resolving.value
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.search),
              label: Text(resolving.value
                  ? "Resolving..."
                  : isSearching.value
                      ? "Searching..."
                      : "Search & Score"),
            ),
          ),
          if (statusMsg.value != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(statusMsg.value!,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          const SizedBox(height: 16),

          // Results
          if (results.value.isNotEmpty) ...[
            Row(children: [
              Text("${results.value.length} results",
                  style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              Text("Total: ${results.value.fold(0, (s, r) => s + r.score)}pts",
                  style: Theme.of(context).textTheme.titleSmall),
            ]),
            const SizedBox(height: 8),
            for (int i = 0; i < results.value.length; i++)
              _ResultCard(
                rank: i + 1,
                result: results.value[i],
                breakdownText: _breakdownText(results.value[i]),
              ),
          ],
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final int rank;
  final _ScoredResult result;
  final String breakdownText;

  const _ResultCard({
    required this.rank,
    required this.result,
    required this.breakdownText,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final score = result.score;
    final color = score >= 60
        ? Colors.green
        : score >= 40
            ? Colors.orange
            : score >= 20
                ? Colors.amber
                : Colors.red;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: color.withValues(alpha: 0.2),
                child: Text("$rank",
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: color)),
              ),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(result.title,
                      style: t.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text("$score",
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: color,
                        fontSize: 16)),
              ),
            ]),
            const SizedBox(height: 4),
            Text(result.artists.join(", "),
                style: t.textTheme.bodySmall?.copyWith(
                    color: t.colorScheme.onSurface.withValues(alpha: 0.7))),
            Text(result.durationStr,
                style: t.textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    color: t.colorScheme.onSurface.withValues(alpha: 0.5))),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: t.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(breakdownText,
                  style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: t.colorScheme.onSurface.withValues(alpha: 0.7))),
            ),
          ],
        ),
      ),
    );
  }
}

/// Re-derives score components for display purposes.
/// This mirrors the logic in SourcedTrack.rankResultsExperimental.
_ScoredResult _scoreBreakdown(
  SpotubeAudioSourceMatchObject sibling,
  SpotubeFullTrackObject track,
) {
  final result = _ScoredResult(
    match: sibling,
    score: 0,
    index: 0,
    title: sibling.title,
    artists: sibling.artists,
    durationStr: "${sibling.duration.inSeconds}s",
  );

  final title = sibling.title.toLowerCase();
  final normalizedTitle = _normalizeST(sibling.title);
  final cleanedNormalizedTitle = _normalizeST(_stripDec(sibling.title));
  final titleTokens = _tokenizeST(cleanedNormalizedTitle);
  final normalizedTrackName = _normalizeST(track.name);
  final cleanedTrackName = _normalizeST(_stripDec(track.name));
  final trackTokens = _tokenizeST(cleanedTrackName);
  final artistNames = track.artists.map((a) => a.name).toList();
  final normalizedArtistNames =
      artistNames.map(_normalizeST).where((n) => n.isNotEmpty).toList();
  final artistTokens = normalizedArtistNames
      .expand(_tokenizeST)
      .where((t) => t.isNotEmpty)
      .toSet();
  final siblingArtists = sibling.artists.map((a) => a.toLowerCase()).toList();
  final normalizedSiblingArtists = siblingArtists.map(_normalizeST).toList();
  final combinedSiblingTokens = {
    ...titleTokens,
    ...normalizedSiblingArtists
        .expand(_tokenizeST)
        .where((t) => t.isNotEmpty)
        .toSet()
  };

  const ytMusicR = r"\b(provided to youtube by|topic)\b";
  const officialAudioR = r"official\s(audio|audio\svideo)";
  const officialMusicR =
      r"official\s(video|audio|music\svideo|lyric\svideo|visualizer)";
  const musicVideoR = r"\b(official\svideo|music\svideo|mv)\b";
  const lyricVideoR = r"\b(lyric\svideo|lyrics?)\b";
  const liveR = r"\b(live|performance|concert|session|acoustic|karaoke)\b";
  const remixR = r"\b(remix|cover|sped\s?up|slowed|nightcore)\b";
  const featuredR = r"\b(ft|feat|featuring)\.?\b";

  // Title matching
  if (normalizedTitle == normalizedTrackName) result.titleExact = 30;
  if (cleanedNormalizedTitle == cleanedTrackName)
    result.titleCleanExact = 32;
  else if (cleanedNormalizedTitle.startsWith(cleanedTrackName))
    result.titlePrefix = 20;
  else if (cleanedNormalizedTitle.contains(cleanedTrackName))
    result.titleContains = 10;

  final titleOverlap = _overlapST(titleTokens, trackTokens);
  result.titleTokenOverlap = (titleOverlap * 28).round();

  // Sequential word bonus
  final normTrackTokens =
      _normalizeST(track.name).split(' ').where((t) => t.isNotEmpty).toList();
  final normTitleTokens = _normalizeST(sibling.title)
      .split(' ')
      .where((t) => t.isNotEmpty)
      .toList();
  {
    int ti = 0;
    int matched = 0;
    for (final tw in normTrackTokens) {
      while (ti < normTitleTokens.length) {
        if (normTitleTokens[ti] == tw) {
          matched++;
          ti++;
          break;
        }
        ti++;
      }
    }
    result.wordOrderBonus = matched * 3;
  }

  final artistOverlap = _overlapST(combinedSiblingTokens, artistTokens);
  result.artistTokenOverlap = (artistOverlap * 18).round();

  if (titleTokens.length > trackTokens.length + 4)
    result.titleLengthPenalty = -6;

  // Artist matching
  var hasStrong = false;
  for (final an in artistNames.map(_normalizeST)) {
    if (normalizedSiblingArtists
        .any((sa) => sa == an || sa.startsWith(an) || an.startsWith(sa))) {
      result.artistExactMatch += 14;
      hasStrong = true;
    }
    if (normalizedTitle.contains(an)) {
      result.artistInTitle += 8;
      hasStrong = true;
    }
  }
  if (!hasStrong)
    result.noArtistPenalty = -18;
  else if (normalizedArtistNames.any((a) =>
      cleanedNormalizedTitle.startsWith("$a ") ||
      cleanedNormalizedTitle.contains(" $a "))) {
    result.artistPrefixBonus = 6;
  }

  // Duration
  final dd = (sibling.duration.inSeconds - (track.durationMs ~/ 1000)).abs();
  if (dd == 0)
    result.durationPoints = 18;
  else if (dd <= 2)
    result.durationPoints = 16;
  else if (dd <= 5)
    result.durationPoints = 12;
  else if (dd <= 10)
    result.durationPoints = 6;
  else if (dd <= 20)
    result.durationPoints = 1;
  else if (dd >= 30) result.durationPoints = -12;

  // Edition/mix/remix bonus
  final editionR = RegExp(
      r'\b(mix|remix|version|edit|rework|flip|bootleg|refix)\b',
      caseSensitive: false);
  if (editionR.hasMatch(_normalizeST(track.name)) &&
      editionR.hasMatch(_normalizeST(sibling.title))) {
    result.editionBonus = 10;
  }

  // Content type bonuses
  if (RegExp(ytMusicR, caseSensitive: false).hasMatch(title) ||
      siblingArtists
          .any((a) => RegExp(ytMusicR, caseSensitive: false).hasMatch(a))) {
    result.ytMusicBonus = 16;
  }
  if (RegExp(officialAudioR, caseSensitive: false).hasMatch(title))
    result.officialAudioBonus = 14;
  if (RegExp(officialMusicR, caseSensitive: false).hasMatch(title))
    result.officialMusicBonus = 8;
  if (title.contains("audio")) result.audioBonus = 4;
  if (RegExp(featuredR, caseSensitive: false).hasMatch(title))
    result.featuredBonus = 2;

  // Penalties
  if (RegExp(musicVideoR, caseSensitive: false).hasMatch(title))
    result.musicVideoPenalty = -18;
  if (RegExp(lyricVideoR, caseSensitive: false).hasMatch(title))
    result.lyricVideoPenalty = -18;
  if (RegExp(liveR, caseSensitive: false).hasMatch(title))
    result.livePenalty = -16;
  if (RegExp(remixR, caseSensitive: false).hasMatch(title))
    result.remixPenalty = -14;

  result.score = result.breakdownTotal;
  return result;
}

String _normalizeST(String v) => v
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _stripDec(String v) => v
    .replaceAll(RegExp(r'\([^)]*\)'), ' ')
    .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
    .replaceAll(
        RegExp(
            r'\b(official|audio|video|lyrics?|lyric video|visualizer|topic|provided to youtube by|music video)\b'),
        ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

Set<String> _tokenizeST(String v) =>
    _normalizeST(v).split(' ').where((p) => p.isNotEmpty).toSet();

double _overlapST(Set<String> l, Set<String> r) {
  if (l.isEmpty || r.isEmpty) return 0;
  return l.intersection(r).length / l.union(r).length;
}
