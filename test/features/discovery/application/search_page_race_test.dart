import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/features/discovery/application/search_page_controller.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

void main() {
  test('duplicate pagination shares a request and late pages cannot overwrite a new query', () async {
    final gateway = _Gateway();
    final container = ProviderContainer(overrides: [sourceContentGatewayProvider.overrideWithValue(gateway)]);
    addTearDown(container.dispose);
    final subscription = container.listen(searchPageControllerProvider, (_, _) {});
    addTearDown(subscription.close);
    await Future<void>.delayed(Duration.zero);
    final controller = container.read(searchPageControllerProvider.notifier);
    await controller.search('first');
    final a = controller.loadMore();
    final b = controller.loadMore();
    expect(gateway.pages, 1);
    await controller.search('second');
    gateway.page.complete(_result('old-page'));
    await Future.wait([a, b]);
    expect(container.read(searchPageControllerProvider).query, 'second');
    expect(gateway.queries, ['first', 'second']);
  });
}

PluginSearchResult _result(String query) => PluginSearchResult(
  pluginId: 'source',
  sourceName: 'source',
  items: const [],
  nextCursor: query == 'first' ? 'next' : null,
  totalCount: 0,
);

final class _Gateway implements SourceContentGateway {
  final queries = <String>[];
  final page = Completer<PluginSearchResult>();
  int pages = 0;
  @override
  Future<List<PluginSourceDescriptor>> listSources() async => [
    PluginSourceDescriptor(id: 'source', displayName: 'source', contentKinds: const [PluginContentKind.novel]),
  ];
  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) {
    if (cursor != null) {
      pages++;
      return page.future;
    }
    queries.add(query);
    return Future.value(_result(query));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
