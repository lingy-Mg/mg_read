// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_router.dart';

// **************************************************************************
// GoRouterGenerator
// **************************************************************************

List<RouteBase> get $appRoutes => [
  $libraryRoute,
  $privateLibraryRoute,
  $readingHistoryRoute,
  $searchRoute,
  $discoveryRoute,
  $profileRoute,
  $readerRoute,
];

RouteBase get $libraryRoute => GoRouteData.$route(
  path: '/',
  hasOverriddenOnExit: false,
  factory: $LibraryRoute._fromState,
);

mixin $LibraryRoute on GoRouteData {
  static LibraryRoute _fromState(GoRouterState state) => const LibraryRoute();

  @override
  String get location => GoRouteData.$location('/');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $privateLibraryRoute => GoRouteData.$route(
  path: '/private-library',
  hasOverriddenOnExit: false,
  factory: $PrivateLibraryRoute._fromState,
);

mixin $PrivateLibraryRoute on GoRouteData {
  static PrivateLibraryRoute _fromState(GoRouterState state) =>
      const PrivateLibraryRoute();

  @override
  String get location => GoRouteData.$location('/private-library');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $readingHistoryRoute => GoRouteData.$route(
  path: '/reading-history',
  hasOverriddenOnExit: false,
  factory: $ReadingHistoryRoute._fromState,
);

mixin $ReadingHistoryRoute on GoRouteData {
  static ReadingHistoryRoute _fromState(GoRouterState state) =>
      const ReadingHistoryRoute();

  @override
  String get location => GoRouteData.$location('/reading-history');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $searchRoute => GoRouteData.$route(
  path: '/search',
  hasOverriddenOnExit: false,
  factory: $SearchRoute._fromState,
);

mixin $SearchRoute on GoRouteData {
  static SearchRoute _fromState(GoRouterState state) =>
      SearchRoute(sourceId: state.uri.queryParameters['source-id']);

  SearchRoute get _self => this as SearchRoute;

  @override
  String get location => GoRouteData.$location(
    '/search',
    queryParams: {if (_self.sourceId != null) 'source-id': _self.sourceId},
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $discoveryRoute => GoRouteData.$route(
  path: '/discover',
  hasOverriddenOnExit: false,
  factory: $DiscoveryRoute._fromState,
);

mixin $DiscoveryRoute on GoRouteData {
  static DiscoveryRoute _fromState(GoRouterState state) =>
      const DiscoveryRoute();

  @override
  String get location => GoRouteData.$location('/discover');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $profileRoute => GoRouteData.$route(
  path: '/profile',
  hasOverriddenOnExit: false,
  factory: $ProfileRoute._fromState,
  routes: [
    GoRouteData.$route(
      path: 'edit',
      hasOverriddenOnExit: false,
      factory: $EditProfileRoute._fromState,
    ),
    GoRouteData.$route(
      path: 'about',
      hasOverriddenOnExit: false,
      factory: $AboutRoute._fromState,
      routes: [
        GoRouteData.$route(
          path: ':itemId',
          hasOverriddenOnExit: false,
          factory: $AboutItemPlaceholderRoute._fromState,
        ),
      ],
    ),
    GoRouteData.$route(
      path: 'feedback',
      hasOverriddenOnExit: false,
      factory: $FeedbackRoute._fromState,
    ),
    GoRouteData.$route(
      path: 'notifications',
      hasOverriddenOnExit: false,
      factory: $NotificationsRoute._fromState,
    ),
    GoRouteData.$route(
      path: 'plugins',
      hasOverriddenOnExit: false,
      factory: $PluginCenterRoute._fromState,
    ),
    GoRouteData.$route(
      path: 'plugins/status',
      hasOverriddenOnExit: false,
      factory: $PluginRuntimeHealthRoute._fromState,
    ),
    GoRouteData.$route(
      path: 'plugins/:pluginId',
      hasOverriddenOnExit: false,
      factory: $PluginSourceDetailRoute._fromState,
    ),
    GoRouteData.$route(
      path: 'plugin-cache',
      hasOverriddenOnExit: false,
      factory: $PluginCacheRoute._fromState,
    ),
    GoRouteData.$route(
      path: 'import-export',
      hasOverriddenOnExit: false,
      factory: $ImportExportRoute._fromState,
    ),
    GoRouteData.$route(
      path: 'diagnostics',
      hasOverriddenOnExit: false,
      factory: $DiagnosticsRoute._fromState,
    ),
    GoRouteData.$route(
      path: 'settings/:settingId',
      hasOverriddenOnExit: false,
      factory: $ProfileSettingPlaceholderRoute._fromState,
    ),
  ],
);

mixin $ProfileRoute on GoRouteData {
  static ProfileRoute _fromState(GoRouterState state) => const ProfileRoute();

  @override
  String get location => GoRouteData.$location('/profile');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $EditProfileRoute on GoRouteData {
  static EditProfileRoute _fromState(GoRouterState state) =>
      const EditProfileRoute();

  @override
  String get location => GoRouteData.$location('/profile/edit');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $AboutRoute on GoRouteData {
  static AboutRoute _fromState(GoRouterState state) => const AboutRoute();

  @override
  String get location => GoRouteData.$location('/profile/about');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $AboutItemPlaceholderRoute on GoRouteData {
  static AboutItemPlaceholderRoute _fromState(GoRouterState state) =>
      AboutItemPlaceholderRoute(itemId: state.pathParameters['itemId']!);

  AboutItemPlaceholderRoute get _self => this as AboutItemPlaceholderRoute;

  @override
  String get location => GoRouteData.$location(
    '/profile/about/${Uri.encodeComponent(_self.itemId)}',
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $FeedbackRoute on GoRouteData {
  static FeedbackRoute _fromState(GoRouterState state) => const FeedbackRoute();

  @override
  String get location => GoRouteData.$location('/profile/feedback');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $NotificationsRoute on GoRouteData {
  static NotificationsRoute _fromState(GoRouterState state) =>
      const NotificationsRoute();

  @override
  String get location => GoRouteData.$location('/profile/notifications');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}
mixin $PluginCenterRoute on GoRouteData {
  static PluginCenterRoute _fromState(GoRouterState state) =>
      const PluginCenterRoute();

  @override
  String get location => GoRouteData.$location('/profile/plugins');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $PluginRuntimeHealthRoute on GoRouteData {
  static PluginRuntimeHealthRoute _fromState(GoRouterState state) =>
      const PluginRuntimeHealthRoute();

  @override
  String get location => GoRouteData.$location('/profile/plugins/status');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $PluginSourceDetailRoute on GoRouteData {
  static PluginSourceDetailRoute _fromState(GoRouterState state) =>
      PluginSourceDetailRoute(pluginId: state.pathParameters['pluginId']!);

  PluginSourceDetailRoute get _self => this as PluginSourceDetailRoute;

  @override
  String get location => GoRouteData.$location(
    '/profile/plugins/${Uri.encodeComponent(_self.pluginId)}',
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $PluginCacheRoute on GoRouteData {
  static PluginCacheRoute _fromState(GoRouterState state) =>
      const PluginCacheRoute();

  @override
  String get location => GoRouteData.$location('/profile/plugin-cache');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $ImportExportRoute on GoRouteData {
  static ImportExportRoute _fromState(GoRouterState state) =>
      const ImportExportRoute();

  @override
  String get location => GoRouteData.$location('/profile/import-export');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $DiagnosticsRoute on GoRouteData {
  static DiagnosticsRoute _fromState(GoRouterState state) =>
      const DiagnosticsRoute();

  @override
  String get location => GoRouteData.$location('/profile/diagnostics');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

mixin $ProfileSettingPlaceholderRoute on GoRouteData {
  static ProfileSettingPlaceholderRoute _fromState(GoRouterState state) =>
      ProfileSettingPlaceholderRoute(
        settingId: state.pathParameters['settingId']!,
      );

  ProfileSettingPlaceholderRoute get _self =>
      this as ProfileSettingPlaceholderRoute;

  @override
  String get location => GoRouteData.$location(
    '/profile/settings/${Uri.encodeComponent(_self.settingId)}',
  );

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}

RouteBase get $readerRoute => GoRouteData.$route(
  path: '/reader/:bookId',
  hasOverriddenOnExit: false,
  factory: $ReaderRoute._fromState,
);

mixin $ReaderRoute on GoRouteData {
  static ReaderRoute _fromState(GoRouterState state) =>
      ReaderRoute(bookId: state.pathParameters['bookId']!);

  ReaderRoute get _self => this as ReaderRoute;

  @override
  String get location =>
      GoRouteData.$location('/reader/${Uri.encodeComponent(_self.bookId)}');

  @override
  void go(BuildContext context) => context.go(location);

  @override
  Future<T?> push<T>(BuildContext context) => context.push<T>(location);

  @override
  void pushReplacement(BuildContext context) =>
      context.pushReplacement(location);

  @override
  void replace(BuildContext context) => context.replace(location);
}
