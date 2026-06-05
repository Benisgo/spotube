import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/services/logger/logger.dart';

final metadataPluginUserProvider = FutureProvider<SpotubeUserObject?>(
  (ref) async {
    final metadataPlugin = await ref.watch(metadataPluginProvider.future);
    final authenticated =
        await ref.watch(metadataPluginAuthenticatedProvider.future);

    if (!authenticated || metadataPlugin == null) {
      return null;
    }
    try {
      return await metadataPlugin.user.me().timeout(const Duration(seconds: 8));
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        return null;
      }
      await AppLogger.reportError(e, e.stackTrace);
      rethrow;
    } on TimeoutException {
      AppLogger.log.w(
        "Timed out while loading the authenticated metadata user profile",
      );
      return null;
    } catch (e) {
      if (e.toString().contains("401")) {
        return null;
      }
      await AppLogger.reportError(e, StackTrace.current);
      rethrow;
    }
  },
);
