import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/sourced_track/sourced_track.dart';

class SourcedTrackNotifier
    extends FamilyAsyncNotifier<SourcedTrack, SpotubeFullTrackObject> {
  @override
  FutureOr<SourcedTrack> build(query) {
    AppLogger.trace("[sourced_track_provider] build track=${query.id}");
    ref.watch(audioSourcePluginProvider);

    return SourcedTrack.fetchFromTrack(query: query, ref: ref);
  }

  Future<SourcedTrack> refreshStreamingUrl() async {
    AppLogger.trace("[sourced_track_provider] refreshStreamingUrl track=${arg.id}");
    return await update((prev) async {
      return await prev.refreshStream();
    });
  }

  Future<SourcedTrack> copyWithSibling() async {
    AppLogger.trace("[sourced_track_provider] copyWithSibling track=${arg.id}");
    return await update((prev) async {
      return prev.copyWithSibling();
    });
  }

  Future<SourcedTrack> swapWithSibling(
    SpotubeAudioSourceMatchObject sibling,
  ) async {
    AppLogger.trace(
      "[sourced_track_provider] swapWithSibling track=${arg.id} sibling=${sibling.id}",
    );
    return await update((prev) async {
      return await prev.swapWithSibling(sibling) ?? prev;
    });
  }

  Future<SourcedTrack> swapWithNextSibling() async {
    AppLogger.trace("[sourced_track_provider] swapWithNextSibling track=${arg.id}");
    return await update((prev) async {
      final withSiblings =
          prev.siblings.isEmpty ? await prev.copyWithSibling() : prev;

      if (withSiblings.siblings.isEmpty) {
        return withSiblings;
      }

      return await withSiblings.swapWithSibling(
            withSiblings.siblings.first,
          ) ??
          withSiblings;
    });
  }
}

final sourcedTrackProvider = AsyncNotifierProviderFamily<SourcedTrackNotifier,
    SourcedTrack, SpotubeFullTrackObject>(
  () => SourcedTrackNotifier(),
);
