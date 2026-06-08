import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shelf/shelf.dart';
import 'package:spotube/services/logger/logger.dart';

final pipelineProvider = Provider((ref) {
  final pipeline = kReleaseMode
      ? const Pipeline().addMiddleware(
          (innerHandler) {
            return (request) async {
              AppLogger.criticalTrace(
                "[server_pipeline] ${request.method} ${request.requestedUri}",
              );
              return innerHandler(request);
            };
          },
        )
      : const Pipeline();

  return pipeline;
});
