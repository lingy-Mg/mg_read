/// Grouped source list and source-card interactions for the discovery picker.
///
/// Rows project app-owned source descriptors only. Runtime transport state and
/// installation details must not enter this presentation library.
part of 'source_picker_sheet.dart';

class _SourcePickerList extends StatelessWidget {
  const _SourcePickerList({
    required this.sources,
    required this.selectedSourceId,
    required this.pinnedSourceIds,
    required this.query,
    required this.hasAnySources,
    required this.onClearQuery,
    required this.onSourcePressed,
    required this.onPinPressed,
    required this.onWebViewAction,
  });

  final List<PluginSourceDescriptor> sources;
  final String? selectedSourceId;
  final List<String> pinnedSourceIds;
  final String query;
  final bool hasAnySources;
  final VoidCallback onClearQuery;
  final ValueChanged<String> onSourcePressed;
  final Future<void> Function(String sourceId) onPinPressed;
  final void Function(String sourceId, DiscoverySourceWebViewAction action) onWebViewAction;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) {
      return _SourcePickerEmptyState(query: query, hasAnySources: hasAnySources, onClearQuery: onClearQuery);
    }
    final pinned = sources.where((source) => pinnedSourceIds.contains(source.id)).toList(growable: false);
    final others = sources.where((source) => !pinnedSourceIds.contains(source.id)).toList(growable: false);
    final entries = <_SourceListEntry>[];
    if (pinned.isNotEmpty) {
      entries.add(_SourceSectionEntry('已置顶', pinned.length));
      entries.addAll(pinned.map(_SourceItemEntry.new));
      if (others.isNotEmpty) entries.add(_SourceSectionEntry('其他数据源', others.length));
    }
    entries.addAll(others.map(_SourceItemEntry.new));

    return ListView.builder(
      key: const Key('discovery-source-picker-list'),
      padding: const EdgeInsets.fromLTRB(AppSpacing.comfortable, AppSpacing.compact, AppSpacing.comfortable, AppSpacing.regular),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return switch (entry) {
          _SourceSectionEntry(:final label, :final count) => _SourcePickerSectionLabel(label: label, count: count),
          _SourceItemEntry(:final source) => Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.compact),
            child: _SourcePickerRow(
              source: source,
              selected: source.id == selectedSourceId,
              pinned: pinnedSourceIds.contains(source.id),
              onPressed: () => onSourcePressed(source.id),
              onPinPressed: () => onPinPressed(source.id),
              onWebViewAction: (action) => onWebViewAction(source.id, action),
            ),
          ),
        };
      },
    );
  }
}

sealed class _SourceListEntry {
  const _SourceListEntry();
}

final class _SourceSectionEntry extends _SourceListEntry {
  const _SourceSectionEntry(this.label, this.count);

  final String label;
  final int count;
}

final class _SourceItemEntry extends _SourceListEntry {
  const _SourceItemEntry(this.source);

  final PluginSourceDescriptor source;
}

class _SourcePickerSectionLabel extends StatelessWidget {
  const _SourcePickerSectionLabel({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.unit, AppSpacing.compact, AppSpacing.unit, AppSpacing.compact),
      child: Row(
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: AppSpacing.unit),
          Text('$count', style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText.withValues(alpha: 0.72))),
        ],
      ),
    );
  }
}

class _SourcePickerEmptyState extends StatelessWidget {
  const _SourcePickerEmptyState({required this.query, required this.hasAnySources, required this.onClearQuery});

  final String query;
  final bool hasAnySources;
  final VoidCallback onClearQuery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final hasQuery = query.trim().isNotEmpty;
    final icon = hasQuery ? Icons.search_off_rounded : Icons.extension_off_outlined;
    final title = hasQuery ? '没有找到“${query.trim()}”' : '还没有数据源';
    final description = hasQuery
        ? '可以尝试名称、类型或数据源功能关键词'
        : hasAnySources
        ? '当前没有可显示的数据源'
        : '添加并启用数据源后即可开始浏览内容';
    return Center(
      key: const Key('discovery-source-picker-empty'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.page),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(color: tokens.mutedSurface, shape: BoxShape.circle),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.regular),
                child: Icon(icon, size: 28, color: tokens.mutedText),
              ),
            ),
            const SizedBox(height: AppSpacing.regular),
            Text(title, textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.unit),
            Text(
              description,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
            ),
            if (hasQuery) ...<Widget>[
              const SizedBox(height: AppSpacing.regular),
              TextButton.icon(onPressed: onClearQuery, icon: const Icon(Icons.close_rounded, size: 18), label: const Text('清除搜索')),
            ],
          ],
        ),
      ),
    );
  }
}

class _AllSourcesPickerRow extends StatelessWidget {
  const _AllSourcesPickerRow({required this.selected, required this.onPressed});

  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final selectedColor = Color.alphaBlend(
      tokens.accent.withValues(alpha: theme.brightness == Brightness.dark ? 0.14 : 0.07),
      tokens.surface,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.comfortable, AppSpacing.regular, AppSpacing.comfortable, 0),
      child: Material(
        color: selected ? selectedColor : theme.colorScheme.surface,
        borderRadius: AppRadii.control,
        child: InkWell(
          key: const Key('discovery-source-picker-all'),
          onTap: onPressed,
          borderRadius: AppRadii.control,
          child: Container(
            constraints: const BoxConstraints(minHeight: 68),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.regular, vertical: AppSpacing.compact),
            decoration: BoxDecoration(
              borderRadius: AppRadii.control,
              border: Border.all(color: selected ? tokens.accent.withValues(alpha: 0.58) : tokens.divider),
            ),
            child: Row(
              children: <Widget>[
                DecoratedBox(
                  decoration: BoxDecoration(color: selected ? tokens.accentSoft : tokens.mutedSurface, shape: BoxShape.circle),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.compact),
                    child: Icon(Icons.all_inclusive_rounded, color: selected ? tokens.accent : tokens.mutedText, size: 22),
                  ),
                ),
                const SizedBox(width: AppSpacing.regular),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text('全部数据源', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text('并行搜索并合并重复结果', style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
                    ],
                  ),
                ),
                if (selected) _SourceStatusBadge(label: '当前', icon: Icons.check_rounded),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SourcePickerRow extends StatelessWidget {
  const _SourcePickerRow({
    required this.source,
    required this.selected,
    required this.pinned,
    required this.onPressed,
    required this.onPinPressed,
    required this.onWebViewAction,
  });

  final PluginSourceDescriptor source;
  final bool selected;
  final bool pinned;
  final VoidCallback onPressed;
  final Future<void> Function() onPinPressed;
  final ValueChanged<DiscoverySourceWebViewAction> onWebViewAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final selectedColor = Color.alphaBlend(
      tokens.accent.withValues(alpha: theme.brightness == Brightness.dark ? 0.14 : 0.065),
      tokens.surface,
    );
    return Semantics(
      button: true,
      selected: selected,
      label: '${selected ? '当前数据源' : '选择数据源'}，${pinned ? '已置顶' : '未置顶'}，${source.displayName}',
      child: GestureDetector(
        onLongPressStart: (details) => _showSourcePickerActions(context, details.globalPosition, pinned, onPinPressed, onWebViewAction),
        onSecondaryTapUp: (details) => _showSourcePickerActions(context, details.globalPosition, pinned, onPinPressed, onWebViewAction),
        child: Material(
          color: selected ? selectedColor : theme.colorScheme.surface,
          borderRadius: AppRadii.control,
          child: InkWell(
            key: ValueKey<String>('discovery-source-picker-${source.id}'),
            onTap: onPressed,
            borderRadius: AppRadii.control,
            child: Container(
              constraints: const BoxConstraints(minHeight: 80),
              padding: const EdgeInsets.fromLTRB(AppSpacing.regular, AppSpacing.compact, AppSpacing.unit, AppSpacing.compact),
              decoration: BoxDecoration(
                borderRadius: AppRadii.control,
                border: Border.all(color: selected ? tokens.accent.withValues(alpha: 0.62) : tokens.divider),
              ),
              child: Row(
                children: <Widget>[
                  SourceIcon(sourceId: source.id, displayName: source.displayName, iconUrl: source.iconUrl, size: 48, borderRadius: 11),
                  const SizedBox(width: AppSpacing.regular),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                source.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.15),
                              ),
                            ),
                            if (selected) ...<Widget>[
                              const SizedBox(width: AppSpacing.compact),
                              const _SourceStatusBadge(label: '当前', icon: Icons.check_rounded),
                            ],
                          ],
                        ),
                        const SizedBox(height: AppSpacing.unit),
                        Text(
                          SourceBranding.description(sourceId: source.id, displayName: source.displayName, value: source.description),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText, height: 1.2),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: ValueKey<String>('discovery-source-picker-pin-${source.id}'),
                    tooltip: pinned ? '取消置顶' : '置顶',
                    onPressed: () => unawaited(onPinPressed()),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                      size: 19,
                      color: pinned ? tokens.accent : tokens.mutedText,
                    ),
                  ),
                  PopupMenuButton<_SourcePickerAction>(
                    key: ValueKey<String>('discovery-source-picker-actions-${source.id}'),
                    tooltip: '更多操作',
                    onSelected: (action) => _handleSourcePickerAction(action, onPinPressed, onWebViewAction),
                    icon: Icon(Icons.more_vert_rounded, size: 20, color: tokens.mutedText),
                    itemBuilder: (context) => _sourcePickerActionItems(pinned),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceStatusBadge extends StatelessWidget {
  const _SourceStatusBadge({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: tokens.accentSoft, borderRadius: AppRadii.pill),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 12, color: tokens.accent),
            const SizedBox(width: 3),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: tokens.accent, fontWeight: FontWeight.w700, height: 1),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showSourcePickerActions(
  BuildContext context,
  Offset globalPosition,
  bool pinned,
  Future<void> Function() onPinPressed,
  ValueChanged<DiscoverySourceWebViewAction> onAction,
) async {
  final overlay = Overlay.of(context).context.findRenderObject();
  if (overlay is! RenderBox) return;
  final action = await showMenu<_SourcePickerAction>(
    context: context,
    position: RelativeRect.fromRect(Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 1, 1), Offset.zero & overlay.size),
    items: _sourcePickerActionItems(pinned),
  );
  if (action != null) _handleSourcePickerAction(action, onPinPressed, onAction);
}

List<PopupMenuEntry<_SourcePickerAction>> _sourcePickerActionItems(bool pinned) {
  return <PopupMenuEntry<_SourcePickerAction>>[
    PopupMenuItem<_SourcePickerAction>(
      value: _SourcePickerAction.togglePin,
      child: ListTile(leading: Icon(pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined), title: Text(pinned ? '取消置顶' : '置顶')),
    ),
    const PopupMenuItem<_SourcePickerAction>(
      value: _SourcePickerAction.enterDebug,
      child: ListTile(leading: Icon(Icons.open_in_browser_rounded), title: Text('进入 WebView 调试')),
    ),
    const PopupMenuItem<_SourcePickerAction>(
      value: _SourcePickerAction.show,
      child: ListTile(leading: Icon(Icons.visibility_rounded), title: Text('显示 WebView')),
    ),
  ];
}

void _handleSourcePickerAction(
  _SourcePickerAction action,
  Future<void> Function() onPinPressed,
  ValueChanged<DiscoverySourceWebViewAction> onAction,
) {
  switch (action) {
    case _SourcePickerAction.togglePin:
      unawaited(onPinPressed());
    case _SourcePickerAction.enterDebug:
      onAction(DiscoverySourceWebViewAction.enterDebug);
    case _SourcePickerAction.show:
      onAction(DiscoverySourceWebViewAction.show);
  }
}

enum _SourcePickerAction { togglePin, enterDebug, show }
