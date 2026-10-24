/// 数据源的路由级临时浏览会话。
///
/// 独立 controller 和内存选择存储保证退出后不改主发现页的位置、选择与最近记录。
/// 内容详情、书架和阅读仍由宿主回调负责；此页不访问 Runtime 协议或磁盘。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/features/discovery/application/discovery_page_controller.dart';
import 'package:mg_read/features/discovery/application/discovery_source_selection_store.dart';
import 'package:mg_read/features/discovery/application/search_page_controller.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

class SourcePreviewPage extends StatefulWidget {
  const SourcePreviewPage({
    required this.sourceId,
    required this.initiallySearch,
    required this.discoveryBuilder,
    required this.searchBuilder,
    super.key,
  });

  final String sourceId;
  final bool initiallySearch;
  final Widget Function(BuildContext, VoidCallback) discoveryBuilder;
  final WidgetBuilder searchBuilder;

  @override
  State<SourcePreviewPage> createState() => _SourcePreviewPageState();
}

class _SourcePreviewPageState extends State<SourcePreviewPage> {
  late bool _search = widget.initiallySearch;
  late bool _seenSearch = widget.initiallySearch;
  late bool _seenDiscovery = !widget.initiallySearch;
  void _showSearch(bool value) => setState(() {
    _search = value;
    if (value) {
      _seenSearch = true;
    } else {
      _seenDiscovery = true;
    }
  });
  late final _selection = PreviewSourceSelectionStore(widget.sourceId);

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [
      discoverySourceSelectionStoreProvider.overrideWithValue(_selection),
      availablePluginSourcesProvider.overrideWith((ref) async {
        ref.watch(pluginRuntimeCatalogChangeProvider);
        final sources = await ref.watch(sourceContentGatewayProvider).listSources();
        return sources.where((source) => source.id == widget.sourceId).toList(growable: false);
      }),
      discoveryPageControllerProvider.overrideWith(DiscoveryPageController.new),
      searchPageControllerProvider.overrideWith(SearchPageController.new),
    ],
    child: SourcePreviewScope(
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              AppSecondaryPageTopBar(
                backButtonKey: const Key('source-preview-back'),
                title: _search ? '临时搜索' : '临时发现',
                onBack: () => Navigator.of(context).pop(),
                actions: [
                  TextButton(
                    key: const Key('source-preview-switch'),
                    onPressed: () => _showSearch(!_search),
                    child: Text(_search ? '浏览发现' : '在此搜索'),
                  ),
                ],
              ),
              Expanded(
                child: Builder(
                  builder: (context) => IndexedStack(
                    index: _search ? 1 : 0,
                    children: [
                      _seenDiscovery ? widget.discoveryBuilder(context, () => _showSearch(true)) : const SizedBox.shrink(),
                      _seenSearch ? widget.searchBuilder(context) : const SizedBox.shrink(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Presentation marker used to suppress top-level navigation inside a preview.
class SourcePreviewScope extends InheritedWidget {
  const SourcePreviewScope({required super.child, super.key});

  static bool active(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SourcePreviewScope>() != null;

  @override
  bool updateShouldNotify(SourcePreviewScope oldWidget) => false;
}

/// A session-local selection store: no persistent selection or pin writes.
class PreviewSourceSelectionStore implements DiscoverySourceSelectionStore {
  PreviewSourceSelectionStore(this.sourceId);

  String sourceId;
  @override
  Future<String?> load() async => sourceId;
  @override
  Future<void> save(String sourceId) async {
    this.sourceId = sourceId;
  }

  @override
  Future<List<String>> loadPinned() async => [];
  @override
  Future<void> setPinned(String sourceId, {required bool pinned}) async {}
}
