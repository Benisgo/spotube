import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/services/logger/logger.dart';

DateTime? _userProfileRetryAfter;

bool _isRecoverableUserProfileError(Object error) {
  if (error is DioException) {
    final statusCode = error.response?.statusCode;
    if (statusCode == 401 || statusCode == 429) {
      return true;
    }
  }

  final message = error.toString().toLowerCase();
  return message.contains("429") ||
      message.contains("401") ||
      message.contains("runtime error: nullobject") ||
      message.contains("calling method [\$sub_getter_] on null object [credentials]") ||
      message.contains("runtime error: undefined") ||
      message.contains("undefined identifier [_timer]");
}

final metadataPluginUserProvider = FutureProvider<SpotubeUserObject?>(
  (ref) async {
    final retryAfter = _userProfileRetryAfter;
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) {
      return null;
    }

    final metadataPlugin = await ref.watch(metadataPluginProvider.future);
    final authenticated =
        await ref.watch(metadataPluginAuthenticatedProvider.future);

    if (!authenticated || metadataPlugin == null) {
      return null;
    }
    try {
      final user =
          await metadataPlugin.user.me().timeout(const Duration(seconds: 8));
      _userProfileRetryAfter = null;
      return user;
    } on DioException catch (e) {
      if (_isRecoverableUserProfileError(e)) {
        _userProfileRetryAfter = DateTime.now().add(const Duration(seconds: 30));
        return null;
      }
      await AppLogger.reportError(e, e.stackTrace);
      rethrow;
    } on TimeoutException {
      _userProfileRetryAfter = DateTime.now().add(const Duration(seconds: 30));
      AppLogger.log.w(
        "Timed out while loading the authenticated metadata user profile",
      );
      return null;
    } catch (e) {
      if (_isRecoverableUserProfileError(e)) {
        _userProfileRetryAfter = DateTime.now().add(const Duration(seconds: 30));
        return null;
      }
      await AppLogger.reportError(e, StackTrace.current);
      rethrow;
    }
  },
);
