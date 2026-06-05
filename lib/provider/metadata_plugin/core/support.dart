import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';

final metadataPluginSupportTextProvider = FutureProvider<String>((ref) async {
  final metadataPlugin = await ref.watch(metadataPluginProvider.future);

  if (metadataPlugin == null) {
    return '';
  }
  return await metadataPlugin.core.support;
});

final audioSourcePluginSupportTextProvider =
    FutureProvider<String>((ref) async {
  final audioSourcePlugin = await ref.watch(audioSourcePluginProvider.future);

  if (audioSourcePlugin == null) {
    return '';
  }
  return await audioSourcePlugin.core.support;
});
