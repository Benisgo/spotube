import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/services/kv_store/kv_store.dart';

class PinnedPlaylistsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() {
    return KVStoreService.pinnedPlaylists;
  }

  void togglePin(String playlistId) {
    if (state.contains(playlistId)) {
      state = state.where((id) => id != playlistId).toList();
    } else {
      state = [...state, playlistId];
    }
    KVStoreService.setPinnedPlaylists(state);
  }
  
  bool isPinned(String playlistId) {
    return state.contains(playlistId);
  }
}

final pinnedPlaylistsProvider =
    NotifierProvider<PinnedPlaylistsNotifier, List<String>>(
  () => PinnedPlaylistsNotifier(),
);
