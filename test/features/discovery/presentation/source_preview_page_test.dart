/// 临时浏览的会话隔离、单源限制和返回测试；不访问真实 Runtime。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/application/discovery_page_controller.dart';
import 'package:mg_read/features/discovery/application/discovery_source_selection_store.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/discovery_destination_page.dart';
import 'package:mg_read/features/discovery/presentation/search_page.dart';
import 'package:mg_read/features/discovery/presentation/source_preview_page.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

void main() {
  testWidgets('temporary discovery and search target only the selected source and retain parent state', (tester) async {
    final gateway = _Gateway();
    final parentSelection = PreviewSourceSelectionStore('primary');
    late ProviderContainer parent;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourceContentGatewayProvider.overrideWithValue(gateway),
          discoverySourceSelectionStoreProvider.overrideWithValue(parentSelection),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Consumer(
            builder: (context, ref, _) {
              parent = ProviderScope.containerOf(context);
              ref.watch(discoveryPageControllerProvider);
              return Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SourcePreviewPage(
                        sourceId: 'secondary',
                        initiallySearch: false,
                        discoveryBuilder: (context, openSearch) =>
                            DiscoveryDestinationPage(onDestinationRequested: (_) {}, onSearchRequested: (_) => openSearch()),
                        searchBuilder: (_) => SearchPage(initialSourceId: 'secondary', onDestinationRequested: (_) {}),
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final original = parent.read(discoveryPageControllerProvider);
    expect(original.selectedSourceId, 'primary');
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('临时发现'), findsOneWidget);
    expect(gateway.discovered, ['primary', 'secondary']);
    expect(find.byType(AppBottomNavigation), findsNothing);
    await tester.tap(find.byKey(const Key('source-preview-switch')));
    await tester.pumpAndSettle();
    expect(find.text('临时搜索'), findsOneWidget);
    expect(gateway.suggested, isNotEmpty);
    expect(gateway.suggested.toSet(), {'secondary'});
    await tester.tap(find.byKey(const Key('source-preview-switch')));
    await tester.pumpAndSettle();
    expect(gateway.discovered, ['primary', 'secondary']);
    await tester.tap(find.text('临时分类'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('runtime-discovery-back')), findsOneWidget);
    expect(gateway.discovered, ['primary', 'secondary', 'secondary']);
    await tester.tap(find.byKey(const Key('runtime-discovery-back')));
    await tester.pumpAndSettle();
    expect(find.text('临时发现'), findsOneWidget);
    await tester.tap(find.byKey(const Key('source-preview-back')));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
    expect(parent.read(discoveryPageControllerProvider), same(original));
    expect(await parentSelection.load(), 'primary');
    expect(tester.takeException(), isNull);
  });
}

class _Gateway implements SourceContentGateway {
  final discovered = <String>[];
  final suggested = <String>[];
  @override
  Future<List<PluginSourceDescriptor>> listSources() async => [
    for (final id in ['primary', 'secondary'])
      PluginSourceDescriptor(id: id, displayName: id, contentKinds: const [PluginContentKind.novel]),
  ];
  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) async {
    discovered.add(pluginId);
    return PluginDiscoveryDocumentResult(
      pluginId: pluginId,
      sourceName: pluginId,
      document: PluginDiscoveryDocument(
        components: [
          if (target == null)
            PluginDiscoveryCategoryCollectionComponent(
              id: 'categories',
              layout: PluginDiscoveryCategoryLayout.chips,
              categories: const [PluginDiscoveryCategory(id: 'category', title: '临时分类', target: 'category', count: null, url: null)],
            ),
        ],
      ),
    );
  }

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) async {
    suggested.add(pluginId);
    return PluginSearchSuggestionsResult(pluginId: pluginId, sourceName: pluginId, items: const [], nextCursor: null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
