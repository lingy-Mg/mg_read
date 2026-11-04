/// A phone's generic confirmation cannot approve local document operations.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_tv_companion.dart';
import 'package:mg_read/features/tv_companion/domain/companion_models.dart';

final _navigate = Provider<Future<void> Function()>(
  (ref) =>
      () => navigateCompanion(ref, 'confirm'),
);

void main() {
  for (final target in ['/local-import', '/local-document/item-1']) {
    testWidgets('remote confirm cannot activate local consent at $target', (tester) async {
      var approvals = 0;
      final router = GoRouter(
        initialLocation: target,
        routes: [
          GoRoute(path: '/', builder: (_, _) => const SizedBox.shrink()),
          GoRoute(
            path: target,
            builder: (_, _) => Scaffold(
              body: Actions(
                actions: {
                  ActivateIntent: CallbackAction<ActivateIntent>(
                    onInvoke: (_) {
                      approvals++;
                      return null;
                    },
                  ),
                },
                child: const Focus(autofocus: true, child: Text('确认导入')),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appRouterProvider.overrideWithValue(router)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, target);
      final container = ProviderScope.containerOf(tester.element(find.text('确认导入')));
      await expectLater(
        container.read(_navigate)(),
        throwsA(isA<CompanionFailure>().having((failure) => failure.code, 'code', 'navigation_unavailable')),
      );
      expect(approvals, 0);
      // Verify that the focused action exists: only the app's consent boundary
      // prevented remote activation, rather than an inert/unfocused fixture.
      Actions.invoke(FocusManager.instance.primaryFocus!.context!, const ActivateIntent());
      expect(approvals, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
