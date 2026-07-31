import 'package:dio/dio.dart';
import 'package:spotube/services/logger/logger.dart';

/// Global [Dio] used across the app for album art, lyrics, stream
/// validation, plugin repo checks, etc.
///
/// It carries a rate-limit interceptor so YouTube/Spotify/CDN 429s are
/// reported once (throttled) instead of flooding the log and freezing the
/// UI, and applies a short backoff so the app stops hammering a
/// rate-limited endpoint.
final globalDio = Dio()..interceptors.add(_RateLimitInterceptor());

class _RateLimitInterceptor extends Interceptor {
  static const _logCooldown = Duration(seconds: 15);
  static const _backoff = Duration(milliseconds: 500);

  DateTime? _lastLoggedAt;
  bool _backoffActive = false;

  bool _isTooManyRequests(DioException err) {
    return err.response?.statusCode == 429;
  }

  void _notifyRateLimited() {
    final now = DateTime.now();
    if (_lastLoggedAt != null &&
        now.difference(_lastLoggedAt!) < _logCooldown) {
      return;
    }
    _lastLoggedAt = now;
    AppLogger.log.w(
      'Rate limited (HTTP 429) — backing off for '
      '${_backoff.inMilliseconds}ms before further network requests.',
    );
  }

  Future<void> _applyBackoff() async {
    if (_backoffActive) return;
    _backoffActive = true;
    await Future<void>.delayed(_backoff);
    _backoffActive = false;
  }

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    if (response.statusCode == 429) {
      _notifyRateLimited();
      // Delay subsequent requests so a rate-limited endpoint gets a breather.
      await _applyBackoff();
    }
    handler.next(response);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (_isTooManyRequests(err)) {
      _notifyRateLimited();
      await _applyBackoff();
    }
    handler.next(err);
  }
}
