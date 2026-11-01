/// Root navigation activity for deferred prompts and launch intent lifetimes.
/// Tagged transient reader/player routes block automatic update checks until
/// removed; ordinary navigation and dialogs do not count as content sessions.
/// Notifications are deferred until after the frame to avoid widget-build writes.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const appContentSessionRouteName = 'mgread.content-session';

final appNavigationActivityProvider = Provider<AppNavigationActivity>((ref) {
  final observer = AppNavigationActivity();
  ref.onDispose(observer.close);
  return observer;
});

final class AppNavigationActivity extends NavigatorObserver {
  final ValueNotifier<int> changes = ValueNotifier(0);
  final Set<Route<dynamic>> _contentRoutes = {};
  bool get hasContentSession => _contentRoutes.isNotEmpty;
  bool _closed = false;
  bool _scheduled = false;
  int revision = 0;
  void close() {
    _closed = true;
    _contentRoutes.clear();
    changes.dispose();
  }

  void _changed() {
    revision++;
    if (_scheduled || _closed) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_closed) changes.value = revision;
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _track(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _contentRoutes.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _contentRoutes.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _contentRoutes.remove(oldRoute);
    _track(newRoute);
    _changed();
  }

  void _track(Route<dynamic>? route) {
    if (route != null && route.settings.name == appContentSessionRouteName) _contentRoutes.add(route);
  }
}
