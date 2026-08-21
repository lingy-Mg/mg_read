import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android Runtime starts and exposes bundled plugins', (
    WidgetTester tester,
  ) async {
    await tester.pump();
    final runtime = PluginRuntime();
    addTearDown(runtime.debugDispose);
    final facadeDiagnostics = <RuntimeDiagnostic>[];
    final diagnosticSubscription = runtime.diagnostics.listen(
      facadeDiagnostics.add,
    );
    addTearDown(diagnosticSubscription.cancel);
    final ping = await runtime.invoke(const RuntimePingInvocation());
    expect(ping.isHealthy, isTrue);
    expect(ping.nodeVersion, isNotEmpty);

    final plugins = await runtime.invoke(const InstalledPluginsInvocation());
    final aisishuwu = plugins.singleWhere(
      (plugin) => plugin.id == 'org.mgread.aisishuwu',
    );
    expect(aisishuwu.status, 'active');

    final discovery = await runtime.invoke(
      const SourceDiscoverInvocation(
        pluginId: 'org.mgread.aisishuwu',
        pageSize: 20,
      ),
    );
    expect(discovery.sections, isNotEmpty);
    expect(discovery.sections.first.layout, PluginDiscoveryLayout.categories);
    expect(discovery.sections.first.categories, isNotEmpty);
    expect(
      facadeDiagnostics
          .where(
            (diagnostic) => diagnostic.code == 'runtime_facade_invoke_started',
          )
          .length,
      greaterThanOrEqualTo(2),
    );
    expect(
      facadeDiagnostics
          .where(
            (diagnostic) =>
                diagnostic.code == 'runtime_facade_invoke_completed',
          )
          .length,
      greaterThanOrEqualTo(2),
    );
  });

  testWidgets(
    'data-source management renders the bundled source in light mode',
    (WidgetTester tester) async {
      await tester.pumpWidget(const ProviderScope(child: MgReadApp()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('app-nav-profile')));
      await tester.pumpAndSettle();

      final Finder profileContent = find.byKey(
        const Key('profile-page-content'),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('profile-setting-source-management')),
        220,
        scrollable: find.descendant(
          of: profileContent,
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(
        find.byKey(const Key('profile-setting-source-management')),
      );
      await tester.pumpAndSettle();

      expect(find.text('管理数据来源'), findsOneWidget);
      expect(find.text('我的数据来源'), findsOneWidget);
      expect(find.byKey(const Key('data-source-qidian')), findsOneWidget);
      expect(
        find.byKey(const Key('data-source-toggle-qidian')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('data-source-add')), findsOneWidget);

      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
      await binding.takeScreenshot('data_source_management_light');
    },
  );

  testWidgets('discovery detail renders a sourced book in light mode', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: MgReadApp()));
    await tester.pumpAndSettle(const Duration(seconds: 45));

    await tester.tap(find.byKey(const Key('app-nav-discover')));
    await tester.pumpAndSettle(const Duration(seconds: 45));

    await tester.tap(
      find.byKey(const Key('runtime-discovery-category-category:71')),
    );
    await tester.pumpAndSettle(const Duration(seconds: 60));

    final Finder firstContent = find.byWidgetPredicate((Widget widget) {
      final Key? key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('runtime-discovery-item-');
    }, description: 'a sourced discovery item');
    expect(firstContent, findsWidgets);

    await tester.tap(firstContent.first);
    await tester.pumpAndSettle(const Duration(seconds: 60));

    expect(
      find.byKey(const Key('source-content-detail-sheet')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('source-detail-cover')), findsOneWidget);
    expect(
      find.byKey(const Key('source-detail-latest-chapter-url')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('source-detail-catalog-url')), findsOneWidget);

    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('discovery_detail_light');
  });
}
