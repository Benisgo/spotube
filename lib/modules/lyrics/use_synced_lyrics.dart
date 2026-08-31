import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotube/provider/audio_player/audio_player_service_provider.dart';
import 'package:spotube/services/logger/logger.dart';

int useSyncedLyrics(
  WidgetRef ref,
  Map<int, String> lyricsMap,
  int delay,
) {
  final audioPlayer = ref.read(audioPlayerServiceProvider);
  final stream = audioPlayer.positionStream;

  final currentTime = useState(0);

  useEffect(() {
    return stream.listen((pos) {
      try {
        if (lyricsMap.containsKey(pos.inSeconds + delay)) {
          currentTime.value = pos.inSeconds + delay;
        }
      } catch (e, stack) {
        AppLogger.reportError(e, stack);
      }
    }).cancel;
  }, [lyricsMap, delay]);

  return (Duration(seconds: currentTime.value)).inSeconds;
}
