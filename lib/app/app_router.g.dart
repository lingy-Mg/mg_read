// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_router.dart';

// **************************************************************************
// GoRouterGenerator
// **************************************************************************

List<RouteBase> get $appRoutes => [$libraryRoute, $profileRoute, $readerRoute];

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

RouteBase get $profileRoute => GoRouteData.$route(
  path: '/profile',
  hasOverriddenOnExit: false,
  factory: $ProfileRoute._fromState,
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
