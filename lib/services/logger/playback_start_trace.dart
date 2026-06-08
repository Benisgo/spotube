import 'package:flutter/foundation.dart';
import 'package:spotube/services/logger/logger.dart';

class _PlaybackStartAttempt {
  final String id;
  final String trackId;
  final DateTime startedAt;
  DateTime lastEventAt;
  bool completed = false;

  _PlaybackStartAttempt({
    required this.id,
    required this.trackId,
    required this.startedAt,
    required this.lastEventAt,
  });
}

class PlaybackStartTrace {
  static const _maxAttempts = 20;
  static final Map<String, _PlaybackStartAttempt> _attemptsById = {};
  static final Map<String, String> _activeAttemptByTrack = {};

  static String begin(
    String trackId, {
    required String trigger,
    Map<String, Object?> data = const {},
  }) {
    if (!kDebugMode) return '';

    final now = DateTime.now();
    final attempt = _PlaybackStartAttempt(
      id: '${trackId}_${now.microsecondsSinceEpoch}',
      trackId: trackId,
      startedAt: now,
      lastEventAt: now,
    );

    _attemptsById[attempt.id] = attempt;
    _activeAttemptByTrack[trackId] = attempt.id;
    _prune();

    _emit(
      attempt,
      'begin',
      data: {
        'trigger': trigger,
        ...data,
      },
    );

    return attempt.id;
  }

  static void markTrack(
    String trackId,
    String phase, {
    Map<String, Object?> data = const {},
  }) {
    if (!kDebugMode) return;
    final attemptId = _activeAttemptByTrack[trackId];
    if (attemptId == null) return;
    markAttempt(attemptId, phase, data: data);
  }

  static void markAttempt(
    String attemptId,
    String phase, {
    Map<String, Object?> data = const {},
  }) {
    if (!kDebugMode || attemptId.isEmpty) return;
    final attempt = _attemptsById[attemptId];
    if (attempt == null || attempt.completed) return;
    _emit(attempt, phase, data: data);
  }

  static void completeTrack(
    String trackId,
    String phase, {
    Map<String, Object?> data = const {},
  }) {
    if (!kDebugMode) return;
    final attemptId = _activeAttemptByTrack[trackId];
    if (attemptId == null) return;
    completeAttempt(attemptId, phase, data: data);
  }

  static void completeAttempt(
    String attemptId,
    String phase, {
    Map<String, Object?> data = const {},
  }) {
    if (!kDebugMode || attemptId.isEmpty) return;
    final attempt = _attemptsById[attemptId];
    if (attempt == null || attempt.completed) return;
    _emit(attempt, phase, data: data);
    attempt.completed = true;
    if (_activeAttemptByTrack[attempt.trackId] == attemptId) {
      _activeAttemptByTrack.remove(attempt.trackId);
    }
  }

  static void failTrack(
    String trackId,
    String phase, {
    Map<String, Object?> data = const {},
  }) {
    completeTrack(trackId, phase, data: {'failed': true, ...data});
  }

  static void cancelTrack(
    String trackId,
    String phase, {
    Map<String, Object?> data = const {},
  }) {
    completeTrack(trackId, phase, data: {'cancelled': true, ...data});
  }

  static void _emit(
    _PlaybackStartAttempt attempt,
    String phase, {
    Map<String, Object?> data = const {},
  }) {
    final now = DateTime.now();
    final elapsedMs = now.difference(attempt.startedAt).inMilliseconds;
    final deltaMs = now.difference(attempt.lastEventAt).inMilliseconds;
    attempt.lastEventAt = now;

    AppLogger.agentDebug(
      'playback_start_trace.dart:$phase',
      phase,
      {
        'attemptId': attempt.id,
        'trackId': attempt.trackId,
        'elapsedMs': elapsedMs,
        'deltaMs': deltaMs,
        ...data,
      },
      hypothesisId: 'PLAYBACK_START',
      runId: 'startup-trace',
    );
  }

  static void _prune() {
    while (_attemptsById.length > _maxAttempts) {
      final oldest = _attemptsById.keys.first;
      final attempt = _attemptsById.remove(oldest);
      if (attempt != null && _activeAttemptByTrack[attempt.trackId] == oldest) {
        _activeAttemptByTrack.remove(attempt.trackId);
      }
    }
  }
}
