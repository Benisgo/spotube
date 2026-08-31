import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotube/services/audio_player/audio_player.dart';

/// Exposes the process-wide [SpotubeAudioPlayer] audio engine singleton.
///
/// The engine instance itself is created once in
/// `services/audio_player/audio_player_impl.dart` and shared across the app;
/// wrapping it in a provider lets widgets, providers and hooks obtain it
/// through Riverpod and allows tests / alternate backends to override it via
/// `ProviderScope(overrides:)`. No lifecycle hooks are attached here because
/// ownership (and disposal) remains with the singleton / [disposeAudioPlayerForClose].
final audioPlayerServiceProvider = Provider<SpotubeAudioPlayer>(
  (ref) => audioPlayer,
);
