/// TV 来源选择的全屏两栏展示；筛选与置顶状态仍由原选择器持有。
/// 保留列表的来源身份与置顶后焦点恢复，菜单关闭后先恢复原控制再修改列表。
part of 'source_picker_sheet.dart';

extension _TvSourcePickerLayout on _DiscoverySourcePickerSheetState {
  Widget _buildTvPicker(Widget list) => TvFocusRegion(
    child: Scaffold(
      appBar: AppBar(title: const Text('选择数据源')),
      body: SafeArea(
        child: TvDiscoveryWorkspace(
          key: const Key('discovery-source-picker-panel'),
          sidebar: ListView(
            padding: const EdgeInsets.all(4),
            children: [
              Text('当前 · $_selectedSourceLabel', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              TvFocusable(
                key: const Key('discovery-source-picker-search-toggle'),
                onPressed: _toggleSearch,
                child: Text(_searchExpanded ? '收起筛选' : '筛选数据源'),
              ),
              if (_searchExpanded) ...[
                const SizedBox(height: 12),
                TvTextInputNavigation(
                  child: TextField(
                    key: const Key('discovery-source-picker-search'),
                    controller: _searchController,
                    autofocus: true,
                    onChanged: _setTvQuery,
                    decoration: const InputDecoration(hintText: '名称或用途', prefixIcon: Icon(Icons.search)),
                  ),
                ),
                if (_query.isNotEmpty) ...[const SizedBox(height: 8), TvFocusable(onPressed: _clearQuery, child: const Text('清空筛选'))],
              ],
              const SizedBox(height: 16),
              if (widget.allowAllSources)
                TvFocusable(
                  key: const Key('discovery-source-picker-all'),
                  selected: widget.selectedSourceId == null,
                  onPressed: () => Navigator.pop(context, const DiscoveryAllSourcesSelected()),
                  child: const Text('全部数据源'),
                ),
              const SizedBox(height: 24),
              TvFocusable(
                key: const Key('discovery-source-picker-manage'),
                onPressed: () => Navigator.pop(context, const DiscoverySourceManagementRequested()),
                child: const Text('管理数据源'),
              ),
              const SizedBox(height: 12),
              TvFocusable(
                onPressed: widget.sources.isEmpty ? null : () => Navigator.pop(context, const DiscoverySourceDebugRequested()),
                child: const Text('数据源检测'),
              ),
              const SizedBox(height: 16),
              Text('共 ${widget.sources.length} 个 · 菜单键查看更多操作', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          child: CustomScrollView(key: const Key('tv-source-picker-scroll'), slivers: [list]),
        ),
      ),
    ),
  );
}

class _TvSourcePickerRow extends StatelessWidget {
  const _TvSourcePickerRow({required this.owner});
  final _SourcePickerRow owner;

  Future<void> _more(BuildContext context) async {
    final returnFocus = FocusManager.instance.primaryFocus;
    final route = DialogRoute<_SourcePickerAction>(
      context: context,
      builder: (context) => TvDiscoveryDialog(
        title: owner.source.displayName,
        actions: [TvFocusable(autofocus: true, onPressed: () => Navigator.pop(context), child: const Text('取消'))],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final entry in {
              _SourcePickerAction.togglePin: owner.pinned ? '取消置顶' : '置顶',
              _SourcePickerAction.enterDebug: '进入 WebView 调试',
              _SourcePickerAction.show: '显示 WebView',
            }.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TvFocusable(onPressed: () => Navigator.pop(context, entry.key), child: Text(entry.value)),
              ),
          ],
        ),
      ),
    );
    final action = await Navigator.of(context).push(route);
    await route.completed;
    if (!context.mounted) return;
    if (action != null) _handleSourcePickerAction(action, owner.onPinPressed, owner.onWebViewAction, returnFocus: returnFocus);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TvFocusable(
        key: ValueKey('discovery-source-picker-${owner.source.id}'),
        selected: owner.selected,
        autofocus: owner.selected,
        onPressed: owner.onPressed,
        onMore: () => _more(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(owner.source.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              SourceBranding.description(sourceId: owner.source.id, displayName: owner.source.displayName, value: owner.source.description),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          TvFocusable(
            key: ValueKey('discovery-source-picker-pin-${owner.source.id}'),
            label: owner.pinned ? '取消置顶' : '置顶',
            onPressed: () => unawaited(owner.onPinPressed()),
            child: Icon(owner.pinned ? Icons.push_pin : Icons.push_pin_outlined),
          ),
          const SizedBox(width: 8),
          TvFocusable(
            key: ValueKey('discovery-source-picker-actions-${owner.source.id}'),
            label: '更多操作',
            onPressed: () => _more(context),
            child: const Icon(Icons.more_horiz),
          ),
        ],
      ),
    ],
  );
}
