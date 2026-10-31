/// 搜索目标页面。
///
/// 职责：
/// - 协调搜索输入、历史、数据源选择与结果展示。
/// - 为搜索结果封面提供共享的异步数据源身份。
///
/// 注意：
/// - 首次进入不主动搜索；封面加载不得延迟搜索结果主体。
/// - 控制器负责异步状态，页面不直接读取 Runtime 或持久化。
/// - 顶级内容与发现、我的共用主入口最大宽度，超宽窗口中保持操作区集中。
///
library;

import 'source_debug_page.dart';

import 'dart:async';

import 'source_preview_page.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/batch_search.dart';
import 'package:mg_read/features/discovery/application/bookshelf_membership.dart';
import 'package:mg_read/features/discovery/application/discovery_bookshelf_saver.dart';
import 'package:mg_read/features/discovery/application/discovery_bookshelf_remover.dart';
import 'package:mg_read/features/discovery/application/search_page_controller.dart';
import 'package:mg_read/features/discovery/application/search_page_state.dart';
import 'package:mg_read/features/discovery/application/search_history_store.dart';
import 'package:mg_read/features/discovery/application/discovery_source_selection_store.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/discovery_page.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_sheet.dart';
import 'package:mg_read/features/discovery/presentation/source_picker_sheet.dart';
import 'package:mg_read/features/discovery/presentation/widgets/search_page_sections.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';
import 'package:mg_read/shared/presentation/widgets/app_page_backdrop.dart';
import 'package:mg_read/shared/presentation/widgets/app_page_title.dart';

/// Search destination. Runtime data remains outside this presentation shell.
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({
    required this.onDestinationRequested,
    this.initialSourceId,
    this.preferVideoSources = false,
    this.onSourceManagementRequested,
    this.onTextChapterRequested,
    this.onComicChapterRequested,
    this.onAudioChapterRequested,
    this.onVideoEpisodeRequested,
    super.key,
  });

  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final String? initialSourceId;

  /// TV entry prefers a video-capable source once; manual selection stays free.
  final bool preferVideoSources;
  final VoidCallback? onSourceManagementRequested;
  final SourceTextChapterRequested? onTextChapterRequested;
  final SourceComicChapterRequested? onComicChapterRequested;
  final SourceAudioChapterRequested? onAudioChapterRequested;
  final SourceVideoEpisodeRequested? onVideoEpisodeRequested;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _queryController = TextEditingController();
  final FocusNode _queryFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final List<String> _history = <String>[];
  int _historyGeneration = 0;
  bool _historyWasCleared = false;
  bool _initialSourceApplied = false;

  @override
  void initState() {
    super.initState();
    _queryController.addListener(_onQueryChanged);
    ref.listenManual<SearchPageState>(searchPageControllerProvider, (_, next) => _applyInitialSource(next), fireImmediately: true);
    unawaited(_loadHistory());
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
    final SearchPageController controller = ref.read(searchPageControllerProvider.notifier);
    final bookshelfMembership = ref.watch(bookshelfMembershipProvider);
    final AggregatedSearchResult? displayedResult = state.result;

    Iterable<PluginContentSummary> relatedContentsFor(String pluginId) sync* {
      for (final entry in displayedResult?.items ?? const <AggregatedSearchItem>[]) {
        final variant = entry.variants.where((hit) => hit.pluginId == pluginId).firstOrNull;
        if (variant != null) yield variant.content;
      }
    }

    Future<void> openContent(AggregatedSearchItem item, {SourceSearchHit? preferredHit}) {
      final hit = preferredHit ?? item.primary;
      final pluginId = hit.pluginId;
      final source = hit.source;
      final remover = ref.read(discoveryBookshelfRemoverProvider);
      final currentMembership = ref.read(bookshelfMembershipProvider);
      return showSourceContentDetailSheet(
        context,
        gateway: ref.read(sourceContentGatewayProvider),
        pluginId: pluginId,
        pluginVersion: source.pluginVersion,
        id: hit.content.id,
        initialContent: hit.content,
        initialSourceName: source.displayName,
        relatedContents: relatedContentsFor(pluginId),
        sourceVariants: item.variants,
        onSourceVariantRequested: (variant) async {
          if (!context.mounted) return;
          Navigator.of(context).pop();
          await Future<void>.delayed(Duration.zero);
          if (context.mounted) unawaited(openContent(item, preferredHit: variant));
        },
        onTextChapterRequested: widget.onTextChapterRequested,
        onComicChapterRequested: widget.onComicChapterRequested,
        onAudioChapterRequested: widget.onAudioChapterRequested,
        onVideoEpisodeRequested: widget.onVideoEpisodeRequested,
        shelfState: currentMembership.contains(pluginId: pluginId, title: hit.content.title)
            ? SourceDetailShelfState.alreadyAdded
            : SourceDetailShelfState.canAdd,
        onAddToShelf: (detail, catalog) => ref.read(discoveryBookshelfSaverProvider).save(source: source, detail: detail, catalog: catalog),
        onRemoveFromShelf: remover == null ? null : () => remover.remove(pluginId: pluginId, title: hit.content.title),
        onRecommendationRequested: (content) {
          for (final entry in displayedResult?.items ?? const <AggregatedSearchItem>[]) {
            final related = entry.variants.where((hit) => hit.pluginId == pluginId && hit.content.id == content.id).firstOrNull;
            if (related != null) return openContent(entry, preferredHit: related);
          }
          return Future<void>.value();
        },
      );
    }

    return Scaffold(
      extendBody: true,
      body: AppPageBackdrop(
        style: AppPageBackdropStyle.search,
        child: SafeArea(
          bottom: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AppSpacing.contentMaxWidth),
              child: ListView(
                key: const Key('search-page-scroll'),
                controller: _scrollController,
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.searchPageHorizontalPadding,
                  AppSpacing.pageHeaderTopPaddingFor(context),
                  AppSpacing.searchPageHorizontalPadding,
                  AppSpacing.bottomNavigationContentBottomPadding + MediaQuery.viewPaddingOf(context).bottom,
                ),
                children: <Widget>[
                  SizedBox(
                    height: AppSpacing.pageHeaderHeight,
                    child: _SearchPageHeader(onSourceManagementRequested: widget.onSourceManagementRequested),
                  ),
                  const SizedBox(height: AppSpacing.compact),
                  _SearchTopBar(
                    queryController: _queryController,
                    queryFocusNode: _queryFocusNode,
                    isSearching: state.status == SearchPageStatus.searching,
                    onSearch: () => _search(controller),
                    onCancel: controller.cancelSearch,
                    onClear: _clearQuery,
                  ),
                  const SizedBox(height: AppSpacing.compact),
                  SearchSuggestionSections(
                    history: List<String>.unmodifiable(_history),
                    onHistorySelected: (String value) => _selectSuggestion(value, controller),
                    onHistoryCleared: _clearHistory,
                    onHotSearchSelected: (String value) => _selectSuggestion(value, controller),
                    hotSearches: state.hotSearches,
                    isSearchStarted: state.query.isNotEmpty,
                    onHotSearchRefreshed: () => unawaited(controller.refreshSuggestions()),
                  ),
                  const SizedBox(height: AppSpacing.regular),
                  SearchResultsSection(
                    hasSources: state.sources.isNotEmpty,
                    onManageSources: widget.onSourceManagementRequested,
                    result: displayedResult,
                    status: state.status,
                    query: state.query,
                    error: state.error,
                    sortOrder: state.sortOrder,
                    onSortOrderChanged: controller.setSortOrder,
                    isInBookshelf: (item) =>
                        bookshelfMembership.contains(pluginId: item.primary.pluginId, title: item.primary.content.title),
                    onContentPressed: (AggregatedSearchItem item) => unawaited(openContent(item)),
                    onRetry: () {
                      if (state.sources.isEmpty) {
                        unawaited(controller.retrySources());
                      } else if (state.result?.failedSources.isNotEmpty ?? false) {
                        unawaited(controller.retryFailedSources());
                      } else {
                        _search(controller);
                      }
                    },
                    onLoadMore: () => unawaited(controller.loadMore()),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SourcePreviewScope.active(context)
          ? null
          : SafeArea(
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

  void _applyInitialSource(SearchPageState state) {
    if (!state.hasSources) return;
    if (state.status != SearchPageStatus.ready) return;
    if (!_initialSourceApplied) {
      _initialSourceApplied = true;
      final currentSource = state.sources.where((source) => source.id == state.selectedSourceId).firstOrNull;
      final preferredSourceId =
          widget.initialSourceId ??
          (widget.preferVideoSources && !(currentSource?.contentKinds.contains(PluginContentKind.video) ?? false)
              ? state.sources.where((source) => source.contentKinds.contains(PluginContentKind.video)).firstOrNull?.id
              : null);
      if (preferredSourceId != null &&
          state.sources.any((source) => source.id == preferredSourceId) &&
          state.selectedSourceId != preferredSourceId) {
        unawaited(ref.read(searchPageControllerProvider.notifier).selectSource(preferredSourceId));
        return;
      }
    }
  }

  void _search(SearchPageController controller) {
    final String query = _queryController.text.trim();
    if (query.isEmpty) {
      unawaited(controller.clear());
      return;
    }
    _queryFocusNode.unfocus();
    _replaceHistory(<String>[query, ..._history.where((item) => item != query)].take(5));
    unawaited(controller.search(query));
  }

  void _clearQuery() {
    _queryController.clear();
    unawaited(ref.read(searchPageControllerProvider.notifier).clear());
  }

  void _clearHistory() {
    _historyGeneration++;
    _historyWasCleared = true;
    setState(_history.clear);
    unawaited(_saveHistory(const <String>[]));
  }

  void _selectSuggestion(String value, SearchPageController controller) {
    _queryController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _search(controller);
  }

  Future<void> _loadHistory() async {
    List<String> loaded;
    try {
      loaded = await ref.read(searchHistoryStoreProvider).load();
    } on Object {
      return;
    }
    if (!mounted) return;

    if (_historyGeneration == 0) {
      setState(() {
        _history
          ..clear()
          ..addAll(loaded.take(5));
      });
      return;
    }
    if (_historyWasCleared) return;

    final merged = <String>[..._history, ...loaded.where((item) => !_history.contains(item))].take(5).toList();
    if (_sameHistory(merged, _history)) return;
    setState(() {
      _history
        ..clear()
        ..addAll(merged);
    });
    unawaited(_saveHistory(merged));
  }

  void _replaceHistory(Iterable<String> next) {
    final replacement = List<String>.of(next.take(5));
    _historyGeneration++;
    _historyWasCleared = false;
    setState(() {
      _history
        ..clear()
        ..addAll(replacement);
    });
    unawaited(_saveHistory(replacement));
  }

  Future<void> _saveHistory(List<String> history) async {
    try {
      await ref.read(searchHistoryStoreProvider).save(history);
    } on Object {
      // Search remains usable when a background persistence attempt fails.
    }
  }

  static bool _sameHistory(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}

class _SearchTopBar extends StatelessWidget {
  const _SearchTopBar({
    required this.queryController,
    required this.queryFocusNode,
    required this.isSearching,
    required this.onSearch,
    required this.onCancel,
    required this.onClear,
  });

  final TextEditingController queryController;
  final FocusNode queryFocusNode;
  final bool isSearching;
  final VoidCallback onSearch;
  final VoidCallback onCancel;
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
                readOnly: isSearching,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) {
                  if (!isSearching) onSearch();
                },
                decoration: InputDecoration(
                  hintText: '书名、作者或关键词',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: AnimatedSwitcher(
                    duration: AppMotion.navigationSelection,
                    switchInCurve: AppMotion.navigationCurve,
                    switchOutCurve: AppMotion.navigationReverseCurve,
                    child: isSearching
                        ? const _SearchFieldProgress()
                        : queryController.text.isEmpty
                        ? const SizedBox.shrink(key: ValueKey<String>('empty'))
                        : IconButton(
                            key: const ValueKey<String>('clear'),
                            tooltip: '清空搜索',
                            onPressed: onClear,
                            icon: const Icon(Icons.cancel_rounded),
                          ),
                  ),
                  filled: true,
                  fillColor: tokens.mutedSurface,
                  contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.compact),
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
            onPressed: isSearching ? onCancel : onSearch,
            child: Text(isSearching ? '取消搜索' : '搜索'),
          ),
        ],
      ),
    );
  }
}

class _SearchFieldProgress extends StatelessWidget {
  const _SearchFieldProgress();

  @override
  Widget build(BuildContext context) => Semantics(
    label: '搜索进行中',
    child: ExcludeSemantics(
      child: Center(
        key: Key('source-search-field-progress'),
        widthFactor: 1,
        heightFactor: 1,
        child: SizedBox(width: AppSpacing.comfortable, height: AppSpacing.comfortable, child: CircularProgressIndicator(strokeWidth: 2)),
      ),
    ),
  );
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
        : state.sources.cast<PluginSourceDescriptor?>().firstWhere((source) => source?.id == state.selectedSourceId, orElse: () => null);
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
          alignment: Alignment.center,
          child: DiscoverySourceSelector(
            key: const Key('search-source-selector-widget'),
            selectorKey: const Key('search-source-selector'),
            sourceName: selectedSource?.displayName ?? '全部数据源',
            onPressed: state.sources.isEmpty ? () {} : () => _showPicker(context, ref, state, controller),
            label: '选择搜索数据源',
          ),
        ),
      ],
    );
  }

  Future<void> _showPicker(BuildContext context, WidgetRef ref, SearchPageState state, SearchPageController controller) async {
    final pinStore = ref.read(discoverySourceSelectionStoreProvider);
    final pinnedSourceIds = await pinStore.loadPinned();
    if (!context.mounted) return;
    final selected = await showDiscoverySourcePicker(
      context,
      sources: state.sources,
      selectedSourceId: state.selectedSourceId,
      allowAllSources: true,
      pinnedSourceIds: pinnedSourceIds,
      onPinChanged: (sourceId, pinned) => pinStore.setPinned(sourceId, pinned: pinned),
    );
    switch (selected) {
      case DiscoverySourceDebugRequested():
        if (!context.mounted) return;
        await showSourceDebugPage(context, gateway: ref.read(sourceContentGatewayProvider), sources: state.sources);
      case DiscoverySourceSelected(:final sourceId):
        await controller.selectSource(sourceId);
      case DiscoveryAllSourcesSelected():
        await controller.selectSource(null);
      case DiscoverySourceManagementRequested():
        onSourceManagementRequested?.call();
      case DiscoverySourceWebViewActionRequested(:final sourceId, :final action):
        final source = state.sources.where((candidate) => candidate.id == sourceId).firstOrNull;
        if (source == null) return;
        try {
          await ref
              .read(pluginRuntimeGatewayProvider)
              .controlSourceWebView(
                pluginId: source.id,
                pluginName: source.displayName,
                action: switch (action) {
                  DiscoverySourceWebViewAction.enterDebug => PluginWebViewDebugAction.enter,
                  DiscoverySourceWebViewAction.show => PluginWebViewDebugAction.show,
                },
              );
        } on AppError {
          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('WebView 调试窗口打开失败，请稍后重试。')));
        }
      case null:
        return;
    }
  }
}
