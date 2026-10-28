/// Production synchronization page with local transport and installer ports.
part of 'lan_sync_page_structure_test.dart';

void _registerLanSyncVisualGoldens() {
  for (final dark in [false, true]) {
    testWidgets('production sync main and pairing sheet ${dark ? 'dark' : 'light'}', (tester) async {
      await loadVisualEvidenceFonts();
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = ProviderContainer(
        overrides: [
          lanSyncGatewayProvider.overrideWithValue(const _Gateway()),
          appUpdateServiceProvider.overrideWithValue(const _AppUpdateService()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: dark ? AppTheme.dark() : AppTheme.light(),
            home: LanSyncPage(onBackRequested: () {}, onDestinationRequested: (_) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-bottom-navigation')), findsNothing);
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/lan_sync_${dark ? 'dark' : 'light'}_main.png'));
      await tester.tap(find.byKey(const Key('device-sync-add-device')));
      await tester.pumpAndSettle();
      expect(find.text('添加设备'), findsAtLeastNWidgets(2));
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/lan_sync_${dark ? 'dark' : 'light'}_pairing.png'));
    });
  }
}
