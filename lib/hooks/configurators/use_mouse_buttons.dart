import 'package:auto_route/auto_route.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:spotube/collections/routes.dart';
import 'package:spotube/utils/platform.dart';

void useMouseNavigationButtons(StackRouter router) {
  final forwardStack = useRef(<String>[]);
  final isBackAction = useRef(false);

  useEffect(() {
    if (!kIsDesktop) return null;

    void onRouterChanged() {
      if (isBackAction.value) {
        isBackAction.value = false;
        return;
      }
      forwardStack.value = [];
    }

    router.addListener(onRouterChanged);

    void globalRoute(PointerEvent event) {
      if (event is! PointerDownEvent) return;

      if (event.buttons & kBackMouseButton != 0) {
        final navigator = rootNavigatorKey.currentState;
        if (navigator != null && navigator.canPop()) {
          forwardStack.value = [...forwardStack.value, router.currentPath];
          router.maybePop();
        }
      } else if (event.buttons & kForwardMouseButton != 0) {
        if (forwardStack.value.isNotEmpty) {
          final path = forwardStack.value.removeLast();
          forwardStack.value = [...forwardStack.value];
          router.navigateNamed(path);
        }
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      GestureBinding.instance.pointerRouter.addGlobalRoute(globalRoute);
    });

    return () {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(globalRoute);
      router.removeListener(onRouterChanged);
    };
  }, [router]);
}
