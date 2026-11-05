/// TV 搜索两栏组合。沿用页面控制器、搜索历史与手机输入会话，不创建第二套请求状态。
/// 输入区固定；来源和建议、搜索结果各自滚动，切换来源或重试仍由应用层管理。
part of 'search_page.dart';

extension _TvSearchLayout on _SearchPageState {
  Widget _buildTvSearch(SearchPageState state, SearchPageController controller, Widget results) => TvFocusRegion(
    child: Scaffold(
      appBar: SourcePreviewScope.active(context)
          ? null
          : AppBottomNavigation(selected: AppNavigationDestination.search, onSelected: widget.onDestinationRequested),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppSpacing.contentMaxWidth),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
                  child: _SearchTopBar(
                    queryController: _queryController,
                    queryFocusNode: _queryFocusNode,
                    submitFocusNode: _submitFocusNode,
                    isSearching: state.status == SearchPageStatus.searching,
                    onSearch: () => _search(controller),
                    onCancel: controller.cancelSearch,
                    onClear: _clearQuery,
                  ),
                ),
                AnimatedBuilder(
                  animation: _companionText,
                  builder: (context, _) => _companionText.active
                      ? Padding(
                          padding: EdgeInsets.all(8),
                          child: Semantics(liveRegion: true, child: Text('手机正在输入，提交后搜索。')),
                        )
                      : const SizedBox.shrink(),
                ),
                Expanded(
                  child: TvDiscoveryWorkspace(
                    key: const Key('tv-search-workspace'),
                    sidebarFraction: .27,
                    sidebar: SingleChildScrollView(
                      key: const Key('tv-search-sidebar'),
                      padding: const EdgeInsets.all(4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _SearchPageHeader(onSourceManagementRequested: widget.onSourceManagementRequested),
                          const SizedBox(height: 24),
                          Text('最近搜索', style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 12),
                          if (_history.isEmpty) const Text('暂无历史关键词'),
                          for (final value in _history)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: TvFocusable(
                                key: ValueKey('tv-search-history-$value'),
                                onPressed: () => _selectSuggestion(value, controller),
                                child: Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
                              ),
                            ),
                          if (_history.isNotEmpty)
                            TvFocusable(key: const Key('search-history-clear'), onPressed: _clearHistory, child: const Text('清空搜索历史')),
                          if (state.hotSearches.isNotEmpty) ...[
                            const SizedBox(height: 24),
                            Text('热门搜索', style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 12),
                            for (var index = 0; index < state.hotSearches.length; index++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: TvFocusable(
                                  key: ValueKey('search-hot-${index + 1}'),
                                  onPressed: () => _selectSuggestion(state.hotSearches[index].query, controller),
                                  child: Text(
                                    '${index + 1}  ${state.hotSearches[index].query}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            TvFocusable(
                              key: const Key('search-hot-refresh'),
                              onPressed: () => unawaited(controller.refreshSuggestions()),
                              child: const Text('换一换'),
                            ),
                          ],
                        ],
                      ),
                    ),
                    child: ListView(
                      key: const Key('search-page-scroll'),
                      controller: _scrollController,
                      padding: const EdgeInsets.all(20),
                      children: [results],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
