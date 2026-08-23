import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/application/discovery_bookshelf_saver.dart';
import 'package:mg_read/features/discovery/application/search_page_controller.dart';
import 'package:mg_read/features/discovery/application/search_page_state.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/discovery_page.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_sheet.dart';
import 'package:mg_read/features/discovery/presentation/source_picker_sheet.dart';
import 'package:mg_read/features/discovery/presentation/widgets/search_page_sections.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';
import 'package:mg_read/shared/presentation/widgets/app_page_title.dart';

/// Search destination. Runtime data remains outside this presentation shell.
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({
    required this.onDestinationRequested,
    this.initialSourceId,
    this.onSourceManagementRequested,
    this.onTextChapterRequested,
    super.key,
  });

  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final String? initialSourceId;
  final VoidCallback? onSourceManagementRequested;
  final SourceTextChapterRequested? onTextChapterRequested;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _queryController = TextEditingController(
    text: SearchPageFixtures.query,
  );
  final FocusNode _queryFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final List<String> _history = List<String>.of(SearchPageFixtures.history);
  bool _initialSearchRequested = false;
  bool _initialSourceApplied = false;

  @override
  void initState() {
    super.initState();
    _queryController.addListener(_onQueryChanged);
    ref.listenManual<SearchPageState>(
      searchPageControllerProvider,
      (_, next) => _maybeSearchInitialQuery(next),
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _queryController
      ..removeListener(_onQueryChanged)
      ..dispose();
    _queryFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final SearchPageState state = ref.watch(searchPageControllerProvider);
    final SearchPageController controller = ref.read(
      searchPageControllerProvider.notifier,
    );
    final PluginSearchResult? displayedResult =
        state.result ??
        (!state.hasSources ? SearchPageFixtures.previewResult : null);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppSpacing.searchPageContentMaxWidth,
            ),
            child: ListView(
              key: const Key('search-page-scroll'),
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.searchPageHorizontalPadding,
                AppSpacing.pageHeaderTopPadding,
                AppSpacing.searchPageHorizontalPadding,
                AppSpacing.section,
              ),
              children: <Widget>[
                SizedBox(
                  height: AppSpacing.pageHeaderHeight,
                  child: _SearchPageHeader(
                    onSourceManagementRequested:
                        widget.onSourceManagementRequested,
                  ),
                ),
                const SizedBox(height: AppSpacing.compact),
                _SearchTopBar(
                  queryController: _queryController,
                  queryFocusNode: _queryFocusNode,
                  isSearching: state.status == SearchPageStatus.searching,
                  onSearch: () => _search(controller),
                  onClear: _clearQuery,
                ),
                const SizedBox(height: AppSpacing.compact),
                SearchSuggestionSections(
                  history: List<String>.unmodifiable(_history),
                  onHistorySelected: (String value) =>
                      _selectSuggestion(value, controller),
                  onHistoryCleared: _clearHistory,
                  onHotSearchSelected: (String value) =>
                      _selectSuggestion(value, controller),
                ),
                const SizedBox(height: AppSpacing.regular),
                SearchResultsSection(
                  result: displayedResult,
                  status: state.status,
                  error: state.error,
                  onContentPressed: (PluginContentSummary content) {
                    final String? pluginId = state.selectedSourceId;
                    if (pluginId == null) return;
                    final source = state.sources.firstWhere(
                      (source) => source.id == pluginId,
                    );
                    unawaited(
                      showSourceContentDetailSheet(
                        context,
                        gateway: ref.read(sourceContentGatewayProvider),
                        pluginId: pluginId,
                        id: content.id,
                        initialContent: content,
                        initialSourceName: source.displayName,
                        relatedContents:
                            displayedResult?.items ??
                            const <PluginContentSummary>[],
                        onTextChapterRequested: widget.onTextChapterRequested,
                        onAddToShelf: (content) => ref
                            .read(discoveryBookshelfSaverProvider)
                            .save(source: source, content: content),
                      ),
                    );
                  },
                  onRetry: () {
                    if (state.sources.isEmpty) {
                      unawaited(controller.retrySources());
                    } else {
                      _search(controller);
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: AppBottomNavigation(
          selected: AppNavigationDestination.search,
          onSelected: (AppNavigationDestination destination) {
            if (destination != AppNavigationDestination.search) {
              widget.onDestinationRequested(destination);
            }
          },
        ),
      ),
    );
  }

  void _onQueryChanged() => setState(() {});

  void _maybeSearchInitialQuery(SearchPageState state) {
    if (_initialSearchRequested || !state.hasSources) return;
    if (state.status != SearchPageStatus.ready) return;
    if (!_initialSourceApplied) {
      _initialSourceApplied = true;
      final preferredSourceId = widget.initialSourceId;
      if (preferredSourceId != null &&
          state.sources.any((source) => source.id == preferredSourceId) &&
          state.selectedSourceId != preferredSourceId) {
        unawaited(
          ref
              .read(searchPageControllerProvider.notifier)
              .selectSource(preferredSourceId),
        );
        return;
      }
    }
    if (_queryController.text.trim().isEmpty) return;
    _initialSearchRequested = true;
    unawaited(
      ref
          .read(searchPageControllerProvider.notifier)
          .search(_queryController.text),
    );
  }

  void _search(SearchPageController controller) {
    final String query = _queryController.text.trim();
    if (query.isEmpty) {
      unawaited(controller.clear());
      return;
    }
    _queryFocusNode.unfocus();
    setState(() {
      _history
        ..remove(query)
        ..insert(0, query);
      if (_history.length > 5) _history.removeLast();
    });
    unawaited(controller.search(query));
  }

  void _clearQuery() {
    _queryController.clear();
    unawaited(ref.read(searchPageControllerProvider.notifier).clear());
  }

  void _clearHistory() => setState(_history.clear);

  void _selectSuggestion(String value, SearchPageController controller) {
    _queryController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _search(controller);
  }
}

/// Reference-only presentation content until the product data contract arrives.
abstract final class SearchPageFixtures {
  static const String query = '诡秘之主';
  static const List<String> history = <String>[
    '诡秘之主',
    '大道朝天',
    '深空彼岸',
    '宿命之环',
    '道诡异仙',
  ];

  static final PluginSearchResult previewResult = PluginSearchResult(
    pluginId: 'presentation.preview',
    sourceName: '界面预览',
    totalCount: 12,
    nextCursor: null,
    items: <PluginContentSummary>[
      _item(
        'preview-1',
        '诡秘之主',
        '爱潜水的乌贼',
        <String>['玄幻', '克苏鲁', '西幻', '穿越'],
        '第1268章 不可名状的低语',
        '1小时前更新',
        '发现 12 个来源',
      ),
      _item(
        'preview-2',
        '诡秘之主：番外与资料集',
        '爱潜水的乌贼',
        <String>['玄幻', '克苏鲁', '西幻', '衍生'],
        '番外 · 愚者之途',
        '3天前更新',
        '发现 6 个来源',
      ),
      _item(
        'preview-3',
        '诡秘之主同人：愚者的旅途',
        '风起云涌',
        <String>['同人', '衍生', '克苏鲁', '二次元'],
        '第95章 新的序列',
        '2天前更新',
        '发现 3 个来源',
      ),
      _item(
        'preview-4',
        '从诡秘之主开始的轮回',
        '歪倒',
        <String>['科幻', '无限流', '诸天', '穿越'],
        '第512章 旧日的呢喃',
        '5小时前更新',
        '发现 4 个来源',
      ),
    ],
  );

  static PluginContentSummary _item(
    String id,
    String title,
    String author,
    List<String> tags,
    String chapter,
    String update,
    String sources,
  ) => PluginContentSummary(
    id: id,
    title: title,
    contentKind: PluginContentKind.novel,
    author: author,
    url: null,
    coverUrl: null,
    description: sources,
    language: null,
    status: PluginContentStatus.ongoing,
    access: PluginAccessKind.unknown,
    wordCount: null,
    chapterCount: null,
    publishedAt: null,
    updatedAt: null,
    latestChapter: PluginLatestChapter(
      id: null,
      title: chapter,
      url: null,
      updatedAt: null,
    ),
    categories: tags,
    tags: const <String>[],
    attributes: <PluginContentAttribute>[
      PluginContentAttribute(
        key: 'searchPreviewUpdate',
        label: '更新',
        value: update,
      ),
    ],
  );
}

class _SearchTopBar extends StatelessWidget {
  const _SearchTopBar({
    required this.queryController,
    required this.queryFocusNode,
    required this.isSearching,
    required this.onSearch,
    required this.onClear,
  });

  final TextEditingController queryController;
  final FocusNode queryFocusNode;
  final bool isSearching;
  final VoidCallback onSearch;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      height: AppSpacing.searchTopBarHeight,
      child: Row(
        children: <Widget>[
          Expanded(
            child: SizedBox(
              height: AppSpacing.searchQueryHeight,
              child: TextField(
                key: const Key('source-search-query'),
                controller: queryController,
                focusNode: queryFocusNode,
                enabled: !isSearching,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => onSearch(),
                decoration: InputDecoration(
                  hintText: '书名、作者或关键词',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: queryController.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清空搜索',
                          onPressed: onClear,
                          icon: const Icon(Icons.cancel_rounded),
                        ),
                  filled: true,
                  fillColor: tokens.mutedSurface,
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: AppSpacing.compact,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: AppRadii.pill,
                    borderSide: BorderSide(color: tokens.divider),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: AppRadii.pill,
                    borderSide: BorderSide(color: tokens.divider),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: AppRadii.pill,
                    borderSide: BorderSide(color: tokens.focusRing),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.unit),
          TextButton(
            key: const Key('source-search-submit'),
            onPressed: isSearching ? null : onSearch,
            child: const Text('搜索'),
          ),
        ],
      ),
    );
  }
}

class _SearchPageHeader extends ConsumerWidget {
  const _SearchPageHeader({this.onSourceManagementRequested});

  final VoidCallback? onSourceManagementRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(searchPageControllerProvider);
    final controller = ref.read(searchPageControllerProvider.notifier);
    final selectedSource = state.selectedSourceId == null
        ? null
        : state.sources.cast<PluginSourceDescriptor?>().firstWhere(
            (source) => source?.id == state.selectedSourceId,
            orElse: () => null,
          );
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        const Positioned(
          left: AppSpacing.discoveryHeaderInset,
          top: 0,
          bottom: 0,
          child: Center(child: AppPageTitle(title: '搜索')),
        ),
        Align(
          alignment: const Alignment(0.08, 0),
          child: DiscoverySourceSelector(
            key: const Key('search-source-selector-widget'),
            selectorKey: const Key('search-source-selector'),
            sourceName: selectedSource?.displayName ?? '选择数据源',
            onPressed: state.selectedSourceId == null
                ? () {}
                : () => _showPicker(context, state, controller),
            label: '选择搜索数据源',
          ),
        ),
      ],
    );
  }

  Future<void> _showPicker(
    BuildContext context,
    SearchPageState state,
    SearchPageController controller,
  ) async {
    final selected = await showDiscoverySourcePicker(
      context,
      sources: state.sources,
      selectedSourceId: state.selectedSourceId!,
    );
    switch (selected) {
      case DiscoverySourceSelected(:final sourceId):
        await controller.selectSource(sourceId);
      case DiscoverySourceManagementRequested():
        onSourceManagementRequested?.call();
      case null:
        return;
    }
  }
}
