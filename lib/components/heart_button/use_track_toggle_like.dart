import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/library/tracks.dart';

typedef UseTrackToggleLike = ({
  bool isLiked,
  bool isLoading,
  Future<void> Function(SpotubeTrackObject track) toggleTrackLike,
});

UseTrackToggleLike useTrackToggleLike(SpotubeTrackObject track, WidgetRef ref) {
  final savedTracksNotifier =
      ref.watch(metadataPluginSavedTracksProvider.notifier);

  final isSavedTrack = ref.watch(metadataPluginIsSavedTrackProvider(track.id));
  final pendingLikeState = useState<bool?>(null);
  final isToggling = useState(false);
  final lastResolvedLikeState =
      useState(getSavedTrackMembershipSnapshot(track.id) ?? false);

  useEffect(() {
    pendingLikeState.value = null;
    isToggling.value = false;
    lastResolvedLikeState.value =
        getSavedTrackMembershipSnapshot(track.id) ?? false;
    return null;
  }, [track.id]);

  useEffect(() {
    final resolvedState = isSavedTrack.asData?.value;
    if (resolvedState != null) {
      lastResolvedLikeState.value = resolvedState;
      if (!isToggling.value) {
        pendingLikeState.value = null;
      }
    }
    return null;
  }, [isSavedTrack.asData?.value, isToggling.value]);

  final effectiveIsLiked =
      pendingLikeState.value ?? lastResolvedLikeState.value;

  return (
    isLiked: effectiveIsLiked,
    isLoading: isToggling.value,
    toggleTrackLike: (track) async {
      if (isToggling.value) return;

      final isLikedTrack = pendingLikeState.value ??
          isSavedTrack.asData?.value ??
          lastResolvedLikeState.value;
      isToggling.value = true;
      pendingLikeState.value = !isLikedTrack;

      try {
        if (isLikedTrack) {
          await savedTracksNotifier.removeFavorite([track]);
        } else {
          await savedTracksNotifier.addFavorite([track]);
        }
        lastResolvedLikeState.value = !isLikedTrack;
      } finally {
        isToggling.value = false;
        pendingLikeState.value = null;
      }
    },
  );
}
