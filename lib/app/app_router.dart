import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/discovery/presentation/discovery_page.dart';
import 'package:mg_read/features/discovery/presentation/search_page.dart';
import 'package:mg_read/features/library/presentation/library_page.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_status_page.dart';
import 'package:mg_read/features/profile/presentation/about_page.dart';
import 'package:mg_read/features/profile/presentation/feedback_page.dart';
import 'package:mg_read/features/profile/presentation/profile_page.dart';
import 'package:mg_read/features/reader/presentation/reader_destination_page.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

part 'app_router.g.dart';

/// Supplies the declarative application router and disposes it with the app.
final appRouterProvider = Provider<GoRouter>((Ref ref) {
  final diagnostics = ref.watch(diagnosticsManagerProvider);
  final GoRouter router = GoRouter(
    routes: $appRoutes,
    errorBuilder: (BuildContext context, GoRouterState state) {
      return const _UnknownRoutePage();
    },
  );
  String? previousRoute;
  void reportRoute() {
    final nextRoute = _stableRouteName(
      router.routerDelegate.currentConfiguration.uri,
    );
    if (nextRoute == previousRoute) return;
    try {
      diagnostics.emit(
        AppDiagnosticEvents.routeChanged,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'fromRoute': previousRoute == null
              ? DiagnosticValue.nullValue
              : DiagnosticValue.string(previousRoute!),
          'toRoute': DiagnosticValue.string(nextRoute),
          'navigationType': DiagnosticValue.string(
            previousRoute == null ? 'initial' : 'routeUpdate',
          ),
        }),
      );
    } catch (_) {
      // Routing remains available if diagnostics is closing or unavailable.
    }
    previousRoute = nextRoute;
  }

  router.routerDelegate.addListener(reportRoute);
  reportRoute();
  ref.onDispose(() {
    router.routerDelegate.removeListener(reportRoute);
    router.dispose();
  });
  return router;
});

String _stableRouteName(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.isEmpty) return 'library';
  return switch (segments.first) {
    'search' => 'search',
    'discover' => 'discovery',
    'reader' => 'reader',
    'profile' when segments.length > 1 && segments[1] == 'about' =>
      'profile.about',
    'profile' when segments.length > 1 && segments[1] == 'feedback' =>
      'profile.feedback',
    'profile' when segments.length > 1 && segments[1] == 'plugins' =>
      'profile.plugins',
    'profile' => 'profile',
    _ => 'unknown',
  };
}

void _goToDestination(
  BuildContext context,
  AppNavigationDestination destination,
) {
  switch (destination) {
    case AppNavigationDestination.home:
      const LibraryRoute().go(context);
      return;
    case AppNavigationDestination.search:
      const SearchRoute().go(context);
      return;
    case AppNavigationDestination.discover:
      const DiscoveryRoute().go(context);
      return;
    case AppNavigationDestination.profile:
      const ProfileRoute().go(context);
      return;
  }
}

Page<void> _topLevelDestinationPage({
  required GoRouterState state,
  required Widget child,
}) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    transitionDuration: AppMotion.destinationTransition,
    reverseTransitionDuration: AppMotion.destinationTransition,
    child: child,
    transitionsBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) {
          final Animation<double> curvedAnimation = CurvedAnimation(
            parent: animation,
            curve: AppMotion.navigationCurve,
            reverseCurve: AppMotion.navigationReverseCurve,
          );
          return FadeTransition(
            key: const Key('top-level-destination-transition'),
            opacity: curvedAnimation,
            child: child,
          );
        },
  );
}

/// The local-library landing route.
@TypedGoRoute<LibraryRoute>(path: '/')
class LibraryRoute extends GoRouteData with $LibraryRoute {
  /// Creates the library landing route.
  const LibraryRoute();

  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) {
    return _topLevelDestinationPage(
      state: state,
      child: LibraryPage(
        onDestinationRequested: (AppNavigationDestination destination) {
          _goToDestination(context, destination);
        },
      ),
    );
  }
}

/// The reserved search route reached from the shared bottom navigation.
@TypedGoRoute<SearchRoute>(path: '/search')
class SearchRoute extends GoRouteData with $SearchRoute {
  /// Creates the blank search destination.
  const SearchRoute();

  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) {
    return _topLevelDestinationPage(
      state: state,
      child: SearchPage(
        onDestinationRequested: (AppNavigationDestination destination) {
          _goToDestination(context, destination);
        },
      ),
    );
  }
}

/// The discovery preview route reached from the shared bottom navigation.
@TypedGoRoute<DiscoveryRoute>(path: '/discover')
class DiscoveryRoute extends GoRouteData with $DiscoveryRoute {
  /// Creates the mobile-first discovery destination.
  const DiscoveryRoute();

  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) {
    return _topLevelDestinationPage(
      state: state,
      child: DiscoveryPage(
        onDestinationRequested: (AppNavigationDestination destination) {
          _goToDestination(context, destination);
        },
      ),
    );
  }
}

/// The visual profile/settings route reached from the shared mobile nav.
@TypedGoRoute<ProfileRoute>(
  path: '/profile',
  routes: <TypedRoute<RouteData>>[
    TypedGoRoute<AboutRoute>(path: 'about'),
    TypedGoRoute<FeedbackRoute>(path: 'feedback'),
    TypedGoRoute<PluginCenterRoute>(path: 'plugins'),
  ],
)
class ProfileRoute extends GoRouteData with $ProfileRoute {
  /// Creates the local profile route.
  const ProfileRoute();

  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) {
    return _topLevelDestinationPage(
      state: state,
      child: ProfilePage(
        onDestinationRequested: (AppNavigationDestination destination) {
          _goToDestination(context, destination);
        },
        onAboutRequested: () {
          const AboutRoute().push(context);
        },
        onFeedbackRequested: () {
          const FeedbackRoute().push(context);
        },
        onPluginCenterRequested: () {
          const PluginCenterRoute().push(context);
        },
      ),
    );
  }
}

/// The profile-owned about surface.
class AboutRoute extends GoRouteData with $AboutRoute {
  const AboutRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return AboutPage(
      onBackRequested: () => _returnToProfile(context),
      onDestinationRequested: (AppNavigationDestination destination) {
        _goToDestination(context, destination);
      },
    );
  }
}

/// The profile-owned local-only feedback form.
class FeedbackRoute extends GoRouteData with $FeedbackRoute {
  const FeedbackRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return FeedbackPage(
      onBackRequested: () => _returnToProfile(context),
      onDestinationRequested: (AppNavigationDestination destination) {
        _goToDestination(context, destination);
      },
    );
  }
}

/// Runtime-backed plugin status reached from source management.
class PluginCenterRoute extends GoRouteData with $PluginCenterRoute {
  const PluginCenterRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return PluginRuntimeStatusPage(
      onBackRequested: () => _returnToProfile(context),
      onDestinationRequested: (AppNavigationDestination destination) {
        _goToDestination(context, destination);
      },
    );
  }
}

void _returnToProfile(BuildContext context) {
  if (context.canPop()) {
    context.pop();
    return;
  }
  const ProfileRoute().go(context);
}

/// A reader intent route carrying only the host-owned stable book identifier.
///
/// M2.1 deliberately does not carry a data source, state store, body, or other
/// mutable object through a route. M5 will resolve [bookId] through an
/// application use case before constructing the existing ReaderHostPage.
@TypedGoRoute<ReaderRoute>(path: '/reader/:bookId')
class ReaderRoute extends GoRouteData with $ReaderRoute {
  /// Creates an intent to open a reader session for [bookId].
  const ReaderRoute({required this.bookId});

  /// Stable host-owned library identifier, never source content or a URL.
  final String bookId;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return ReaderDestinationPage(bookId: bookId);
  }
}

class _UnknownRoutePage extends StatelessWidget {
  const _UnknownRoutePage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('页面不存在')),
      body: const SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('请求的页面无法打开，请返回书架后重试。', textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}
