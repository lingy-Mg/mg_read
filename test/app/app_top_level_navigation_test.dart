import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_destination_page.dart';
import 'package:mg_read/features/discovery/presentation/search_page.dart';
import 'package:mg_read/features/library/presentation/library_page.dart';
import 'package:mg_read/features/library/presentation/private_library_page.dart';
import 'package:mg_read/features/import_export/presentation/import_export_page.dart';
import 'package:mg_read/features/profile/presentation/profile_page.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

import 'mg_read_app_test_support.dart';

void main() {
  testWidgets('switches each top-level destination through its route and preserves route-owned selection', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();

    expect(find.byType(LibraryPage), findsOneWidget);
    _expectSelectedDestination(tester, AppNavigationDestination.home);
    final double initialIndicatorX = tester.getRect(find.byKey(const Key('app-bottom-navigation-moving-indicator'))).center.dx;

    await tester.tap(find.byKey(const Key('app-nav-search')));
    await tester.pump();
    expect(find.byKey(const Key('top-level-destination-transition')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.getRect(find.byKey(const Key('app-bottom-navigation-moving-indicator')).first).center.dx, greaterThan(initialIndicatorX));
    await tester.pumpAndSettle();
    expect(find.byType(SearchPage), findsOneWidget);
    expect(find.byKey(const Key('source-search-query')), findsOneWidget);
    _expectSelectedDestination(tester, AppNavigationDestination.search);

    await tester.tap(find.byKey(const Key('app-nav-discover')));
    await tester.pumpAndSettle();
    expect(find.byType(DiscoveryDestinationPage), findsOneWidget);
    expect(find.byKey(const Key('discovery-no-sources')), findsOneWidget);
    _expectSelectedDestination(tester, AppNavigationDestination.discover);

    await tester.tap(find.byKey(const Key('app-nav-profile')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePage), findsOneWidget);
    _expectSelectedDestination(tester, AppNavigationDestination.profile);

    await tester.tap(find.byKey(const Key('app-nav-home')));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryPage), findsOneWidget);
    _expectSelectedDestination(tester, AppNavigationDestination.home);
    semantics.dispose();
  });

  testWidgets('long pressing home reveals and opens private library mode', (WidgetTester tester) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const Key('app-nav-home')));
    await tester.pump();
    expect(find.byKey(const Key('private-library-reveal')), findsOneWidget);

    await tester.pump(AppMotion.privacyModeReveal);
    await tester.pump(AppMotion.destinationTransition);
    await tester.pumpAndSettle();

    expect(find.byType(PrivateLibraryPage), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('app-nav-home')), matching: find.byIcon(Icons.visibility_off_rounded)), findsOneWidget);
  });

  testWidgets('opens import export from My and returns through the secondary route', (WidgetTester tester) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('app-nav-profile')));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const Key('profile-page-content')), const Offset(0, -420));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-setting-import-export')));
    await tester.pumpAndSettle();

    expect(find.byType(ImportExportPage), findsOneWidget);
    expect(find.byType(ProfilePage), findsNothing);
    await tester.tap(find.byKey(const Key('import-export-back')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePage), findsOneWidget);
  });
}

void _expectSelectedDestination(WidgetTester tester, AppNavigationDestination selected) {
  for (final AppNavigationDestination destination in AppNavigationDestination.values) {
    final SemanticsNode node = tester.getSemantics(find.byKey(Key('app-nav-${destination.name}')));
    expect(
      node.flagsCollection.isSelected,
      destination == selected ? Tristate.isTrue : Tristate.isFalse,
      reason: '${destination.name} should ${destination == selected ? '' : 'not '}be active',
    );
  }
}
