import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/features/library/presentation/library_page.dart';
import 'package:mg_read/features/reader/presentation/reader_destination_page.dart';

part 'app_router.g.dart';

/// Supplies the declarative application router and disposes it with the app.
final appRouterProvider = Provider<GoRouter>((Ref ref) {
  final GoRouter router = GoRouter(
    routes: $appRoutes,
    errorBuilder: (BuildContext context, GoRouterState state) {
      return const _UnknownRoutePage();
    },
  );
  ref.onDispose(router.dispose);
  return router;
});

/// The local-library landing route.
@TypedGoRoute<LibraryRoute>(path: '/')
class LibraryRoute extends GoRouteData with $LibraryRoute {
  /// Creates the library landing route.
  const LibraryRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return const LibraryPage();
  }
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
      appBar: AppBar(title: const Text(AppStrings.routeNotFoundTitle)),
      body: const SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              AppStrings.routeNotFoundDescription,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
