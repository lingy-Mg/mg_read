import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/diagnostics/presentation/diagnostics_viewer_page.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/discovery_destination_page.dart';
import 'package:mg_read/features/discovery/presentation/search_page.dart';
import 'package:mg_read/features/library/presentation/library_page.dart';
import 'package:mg_read/features/library/presentation/private_library_page.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_status_page.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_health_page.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_source_detail_page.dart';
import 'package:mg_read/features/plugins/presentation/plugin_cache_management_page.dart';
import 'package:mg_read/features/profile/presentation/about_page.dart';
import 'package:mg_read/features/profile/presentation/about_item_placeholder_page.dart';
import 'package:mg_read/features/profile/presentation/feedback_page.dart';
import 'package:mg_read/features/profile/presentation/profile_page.dart';
import 'package:mg_read/features/profile/application/profile_reading_stats_loader.dart';
import 'package:mg_read/features/profile/presentation/profile_setting_placeholder_page.dart';
import 'package:mg_read/features/reader/presentation/reader_destination_page.dart';
import 'package:mg_read/features/reader/data/transient_source_text_reader.dart';
import 'package:mg_read/features/reader/presentation/reader_host_page.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

part 'app_router.g.dart';

/// Owns imperative overlays that cannot use a route-builder [BuildContext].
final GlobalKey<NavigatorState> appRootNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'mgReadRootNavigator',
);

/// Gives page-owned [PopScope] handlers first chance to consume a back action.
///
/// Discovery uses this for its in-page category stack. A page may report that
/// it handled back without changing the GoRouter location, so the global
/// keyboard and mouse handlers must use `maybePop` instead of `router.pop()`.
Future<bool> popApplicationRoute() async {
  final NavigatorState? navigator = appRootNavigatorKey.currentState;
  if (navigator == null) return false;
  return navigator.maybePop();
}

/// Supplies the declarative application router and disposes it with the app.
final appRouterProvider = Provider<GoRouter>((Ref ref) {
  final diagnostics = ref.watch(diagnosticsManagerProvider);
  final GoRouter router = GoRouter(
    navigatorKey: appRootNavigatorKey,
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
    'private-library' => 'library.private',
    'profile' when segments.length > 2 && segments[1] == 'about' =>
      'profile.about.${segments[2]}',
    'profile' when segments.length > 1 && segments[1] == 'about' =>
      'profile.about',
    'profile' when segments.length > 1 && segments[1] == 'feedback' =>
      'profile.feedback',
    'profile' when segments.length > 2 && segments[1] == 'plugins' =>
      'profile.plugins.${segments[2]}',
    'profile' when segments.length > 1 && segments[1] == 'plugins' =>
      'profile.plugins',
    'profile' when segments.length > 1 && segments[1] == 'plugin-cache' =>
      'profile.pluginCache',
    'profile' when segments.length > 1 && segments[1] == 'diagnostics' =>
      'profile.diagnostics',
    'profile' when segments.length > 2 && segments[1] == 'settings' =>
      'profile.settings.${segments[2]}',
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
        onReaderRequested: (String bookId) {
          ReaderRoute(bookId: bookId).push(context);
        },
        onPrivacyLibraryRequested: () {
          const PrivateLibraryRoute().push(context);
        },
      ),
    );
  }
}

/// Privacy-only bookshelf reached from the library overflow menu.
@TypedGoRoute<PrivateLibraryRoute>(path: '/private-library')
class PrivateLibraryRoute extends GoRouteData with $PrivateLibraryRoute {
  const PrivateLibraryRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => PrivateLibraryPage(
    onBackRequested: () => _returnToLibrary(context),
    onDestinationRequested: (destination) =>
        _goToDestination(context, destination),
    onReaderRequested: (bookId) => ReaderRoute(bookId: bookId).push(context),
  );
}

/// Runtime-backed source search reached from the shared bottom navigation.
@TypedGoRoute<SearchRoute>(path: '/search')
class SearchRoute extends GoRouteData with $SearchRoute {
  /// Creates the source search destination.
  const SearchRoute({this.sourceId});

  final String? sourceId;

  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) {
    return _topLevelDestinationPage(
      state: state,
      child: SearchPage(
        initialSourceId: sourceId,
        onDestinationRequested: (AppNavigationDestination destination) {
          _goToDestination(context, destination);
        },
        onSourceManagementRequested: () {
          const PluginCenterRoute().push(context);
        },
        onTextChapterRequested:
            ({required detail, required firstCatalogPage, required chapter}) {
              return _openTransientSourceTextReader(
                context,
                detail: detail,
                firstCatalogPage: firstCatalogPage,
                chapter: chapter,
              );
            },
      ),
    );
  }
}

/// Runtime-backed discovery route reached from the shared bottom navigation.
@TypedGoRoute<DiscoveryRoute>(path: '/discover')
class DiscoveryRoute extends GoRouteData with $DiscoveryRoute {
  /// Creates the mobile-first discovery destination.
  const DiscoveryRoute();

  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) {
    return _topLevelDestinationPage(
      state: state,
      child: DiscoveryDestinationPage(
        onDestinationRequested: (AppNavigationDestination destination) {
          _goToDestination(context, destination);
        },
        onSearchRequested: (String? sourceId) {
          SearchRoute(sourceId: sourceId).go(context);
        },
        onSourceManagementRequested: () {
          const PluginCenterRoute().push(context);
        },
        onTextChapterRequested:
            ({required detail, required firstCatalogPage, required chapter}) {
              return _openTransientSourceTextReader(
                context,
                detail: detail,
                firstCatalogPage: firstCatalogPage,
                chapter: chapter,
              );
            },
      ),
    );
  }
}

/// Opens a route-lifetime reader session without writing source data or state.
Future<void> _openTransientSourceTextReader(
  BuildContext context, {
  required PluginContentDetail detail,
  required PluginChaptersResult firstCatalogPage,
  required PluginChapterSummary chapter,
}) async {
  final navigator = appRootNavigatorKey.currentState;
  if (navigator == null) {
    throw StateError('The application navigator is not ready.');
  }
  final gateway = ProviderScope.containerOf(
    context,
  ).read(sourceContentGatewayProvider);
  final session = TransientSourceTextReader(
    detail: detail,
    catalog: firstCatalogPage,
    loadChapterContent: (String chapterId) {
      return gateway.getContent(
        pluginId: detail.pluginId,
        id: detail.summary.id,
        chapterId: chapterId,
      );
    },
  );
  await navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (BuildContext routeContext) => ReaderHostPage(
        request: session.createLaunchRequest(
          initialChapterId: chapter.id,
          observer: _DismissReaderObserver(navigator),
        ),
      ),
    ),
  );
}

final class _DismissReaderObserver extends ReaderObserver {
  const _DismissReaderObserver(this._navigator);

  final NavigatorState _navigator;

  @override
  Future<void> onExitRequested(ReaderProgress? progress) async {
    // TextReaderView uses PopScope(canPop: false) to funnel system back
    // gestures through its async progress flush. Once that callback reaches
    // the host, maybePop() would be intercepted by the same PopScope again.
    // This is now an explicit, already-guarded exit request, so pop the route
    // programmatically instead of re-entering the interception path.
    if (_navigator.mounted) _navigator.pop();
  }
}

/// The visual profile/settings route reached from the shared mobile nav.
@TypedGoRoute<ProfileRoute>(
  path: '/profile',
  routes: <TypedRoute<RouteData>>[
    TypedGoRoute<AboutRoute>(
      path: 'about',
      routes: <TypedRoute<RouteData>>[
        TypedGoRoute<AboutItemPlaceholderRoute>(path: ':itemId'),
      ],
    ),
    TypedGoRoute<FeedbackRoute>(path: 'feedback'),
    TypedGoRoute<PluginCenterRoute>(path: 'plugins'),
    TypedGoRoute<PluginRuntimeHealthRoute>(path: 'plugins/status'),
    TypedGoRoute<PluginSourceDetailRoute>(path: 'plugins/:pluginId'),
    TypedGoRoute<PluginCacheRoute>(path: 'plugin-cache'),
    TypedGoRoute<DiagnosticsRoute>(path: 'diagnostics'),
    TypedGoRoute<ProfileSettingPlaceholderRoute>(path: 'settings/:settingId'),
  ],
)
class ProfileRoute extends GoRouteData with $ProfileRoute {
  /// Creates the local profile route.
  const ProfileRoute();

  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) {
    return _topLevelDestinationPage(
      state: state,
      child: Consumer(
        builder: (BuildContext context, WidgetRef ref, Widget? child) {
          final stats = ref.watch(profileReadingStatsProvider).asData?.value;
          return ProfilePage(
            readingStats: stats,
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
            onPluginCacheRequested: () {
              const PluginCacheRoute().push(context);
            },
            onPendingSettingRequested: (String settingId) {
              ProfileSettingPlaceholderRoute(
                settingId: settingId,
              ).push(context);
            },
            onDiagnosticsRequested: () {
              const DiagnosticsRoute().push(context);
            },
          );
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
      onItemRequested: (String itemId) {
        AboutItemPlaceholderRoute(itemId: itemId).push(context);
      },
    );
  }
}

/// Empty third-level page for an item under the profile's about page.
class AboutItemPlaceholderRoute extends GoRouteData
    with $AboutItemPlaceholderRoute {
  const AboutItemPlaceholderRoute({required this.itemId});

  final String itemId;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return AboutItemPlaceholderPage(
      itemId: itemId,
      onBackRequested: () {
        if (context.canPop()) {
          context.pop();
          return;
        }
        const AboutRoute().go(context);
      },
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

/// Runtime-backed data-source management reached from profile settings.
class PluginCenterRoute extends GoRouteData with $PluginCenterRoute {
  const PluginCenterRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return PluginRuntimeStatusPage(
      onBackRequested: () => _returnToProfile(context),
      onDestinationRequested: (AppNavigationDestination destination) {
        _goToDestination(context, destination);
      },
      onSourcePressed: (String pluginId) {
        PluginSourceDetailRoute(pluginId: pluginId).push(context);
      },
      onRuntimeStatusRequested: () {
        const PluginRuntimeHealthRoute().push(context);
      },
    );
  }
}

/// Runtime-owned Node and data-source health overview.
class PluginRuntimeHealthRoute extends GoRouteData
    with $PluginRuntimeHealthRoute {
  const PluginRuntimeHealthRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return PluginRuntimeHealthPage(
      onBackRequested: () {
        if (context.canPop()) {
          context.pop();
          return;
        }
        const PluginCenterRoute().go(context);
      },
    );
  }
}

/// Runtime-backed detail for one data-source projection.
class PluginSourceDetailRoute extends GoRouteData
    with $PluginSourceDetailRoute {
  const PluginSourceDetailRoute({required this.pluginId});

  final String pluginId;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return PluginRuntimeSourceDetailPage(
      pluginId: pluginId,
      onBackRequested: () {
        if (context.canPop()) {
          context.pop();
          return;
        }
        const PluginCenterRoute().go(context);
      },
    );
  }
}

/// Runtime-backed cache maintenance reached from profile settings.
class PluginCacheRoute extends GoRouteData with $PluginCacheRoute {
  const PluginCacheRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return PluginCacheManagementPage(
      onBackRequested: () => _returnToProfile(context),
      onDestinationRequested: (AppNavigationDestination destination) {
        _goToDestination(context, destination);
      },
    );
  }
}

/// Dedicated diagnostics viewer reached from profile tools.
class DiagnosticsRoute extends GoRouteData with $DiagnosticsRoute {
  const DiagnosticsRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return DiagnosticsViewerPage(
      onBackRequested: () => _returnToProfile(context),
      onDestinationRequested: (AppNavigationDestination destination) {
        _goToDestination(context, destination);
      },
    );
  }
}

/// Empty secondary page for a profile setting awaiting its capability.
class ProfileSettingPlaceholderRoute extends GoRouteData
    with $ProfileSettingPlaceholderRoute {
  const ProfileSettingPlaceholderRoute({required this.settingId});

  final String settingId;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return ProfileSettingPlaceholderPage(
      settingId: settingId,
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

void _returnToLibrary(BuildContext context) {
  if (context.canPop()) {
    context.pop();
    return;
  }
  const LibraryRoute().go(context);
}

/// A reader intent route carrying only the host-owned stable book identifier.
///
/// The destination resolves [bookId] through the app-owned reader launcher;
/// source data, content, and state-store dependencies never travel in a route.
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
