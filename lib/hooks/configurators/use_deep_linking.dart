import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/collections/routes.dart';
import 'package:spotube/provider/multi_session/multi_session.dart';
import 'package:spotube/services/logger/logger.dart';

final appLinks = AppLinks();
final linkStream = appLinks.stringLinkStream.asBroadcastStream();

void useDeepLinking(WidgetRef ref, AppRouter router) {
  useEffect(() {
    Future<void> handleLink(String? uriString) async {
      if (uriString == null || uriString.isEmpty) return;

      try {
        await ref.read(multiSessionProvider.notifier).resolveInviteUri(uriString);
        final rootContext = rootNavigatorKey.currentContext;
        if (rootContext == null || !rootContext.mounted) return;
        router.navigate(const ConnectRoute());
      } catch (e, stack) {
        AppLogger.reportError(e, stack);
      }
    }

    final subscription = linkStream.listen((uri) {
      unawaited(handleLink(uri));
    });

    unawaited(appLinks.getInitialLinkString().then(handleLink));

    return subscription.cancel;
  }, [ref, router]);
}
