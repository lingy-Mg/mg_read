/// Production cache page with only its I/O ports replaced by local fixtures.
part of 'cache_management_page_test.dart';

void _registerCacheVisualGoldens() {
  for (final dark in [false, true]) {
    testWidgets('production cache top and image sections ${dark ? 'dark' : 'light'}', (tester) async {
      await loadVisualEvidenceFonts();
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            coverCacheGatewayProvider.overrideWithValue(_CoverCacheGateway()),
            mangaImageCacheGatewayProvider.overrideWithValue(_MangaImageCacheGateway()),
            databaseCacheGatewayProvider.overrideWithValue(_DatabaseCacheGateway()),
            pluginCacheGatewayProvider.overrideWithValue(const _PluginCacheGateway()),
            pluginRuntimeConnectionProvider.overrideWith(
              (ref) async => const PluginRuntimeConnection(isHealthy: true, nodeVersion: 'test', runtimeVersion: 'test', plugins: []),
            ),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: dark ? AppTheme.dark() : AppTheme.light(),
            home: CacheManagementPage(onBackRequested: () {}, onDestinationRequested: (_) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-bottom-navigation')), findsNothing);
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/cache_management_${dark ? 'dark' : 'light'}_top.png'));
      await tester.scrollUntilVisible(
        find.text('漫画正文图片缓存'),
        240,
        scrollable: find.descendant(of: find.byKey(const Key('cache-management-content')), matching: find.byType(Scrollable)),
      );
      await tester.pumpAndSettle();
      expect(find.text('漫画正文图片缓存'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/cache_management_${dark ? 'dark' : 'light'}_images.png'));
    });
  }
}
