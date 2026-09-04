import 'dart:async';

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/shared/presentation/source_branding.dart';

/// Result returned by the discovery source picker.
sealed class DiscoverySourcePickerResult {
  const DiscoverySourcePickerResult();
}

/// The user selected an enabled source for the discovery page.
final class DiscoverySourceSelected extends DiscoverySourcePickerResult {
  const DiscoverySourceSelected(this.sourceId);

  final String sourceId;
}

/// The user requested the Runtime-owned source management surface.
final class DiscoverySourceManagementRequested extends DiscoverySourcePickerResult {
  const DiscoverySourceManagementRequested();
}

enum DiscoverySourceWebViewAction { enterDebug, show }

final class DiscoverySourceWebViewActionRequested extends DiscoverySourcePickerResult {
  const DiscoverySourceWebViewActionRequested({required this.sourceId, required this.action});

  final String sourceId;
  final DiscoverySourceWebViewAction action;
}

/// Shows the discovery source picker without exposing Runtime installation data.
Future<DiscoverySourcePickerResult?> showDiscoverySourcePicker(
  BuildContext context, {
  required List<PluginSourceDescriptor> sources,
  required String selectedSourceId,
  Iterable<String> pinnedSourceIds = const <String>[],
  Future<void> Function(String sourceId, bool pinned)? onPinChanged,
}) {
  return showModalBottomSheet<DiscoverySourcePickerResult>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.30),
    elevation: 0,
    builder: (context) => _DiscoverySourcePickerSheet(
      sources: sources,
      selectedSourceId: selectedSourceId,
      pinnedSourceIds: pinnedSourceIds,
      onPinChanged: onPinChanged,
    ),
  );
}

enum _SourceFilter { all, enabled, recent }

class _DiscoverySourcePickerSheet extends StatefulWidget {
  _DiscoverySourcePickerSheet({
    required this.sources,
    required this.selectedSourceId,
    required Iterable<String> pinnedSourceIds,
    this.onPinChanged,
  }) : pinnedSourceIds = List<String>.unmodifiable(pinnedSourceIds);

  final List<PluginSourceDescriptor> sources;
  final String selectedSourceId;
  final List<String> pinnedSourceIds;
  final Future<void> Function(String sourceId, bool pinned)? onPinChanged;

  @override
  State<_DiscoverySourcePickerSheet> createState() => _DiscoverySourcePickerSheetState();
}

class _DiscoverySourcePickerSheetState extends State<_DiscoverySourcePickerSheet> {
  _SourceFilter _filter = _SourceFilter.all;
  String _query = '';
  late List<String> _pinnedSourceIds;

  @override
  void initState() {
    super.initState();
    _pinnedSourceIds = List<String>.of(widget.pinnedSourceIds);
  }

  List<PluginSourceDescriptor> get _visibleSources {
    final query = _query.trim().toLowerCase();
    final visible = widget.sources.where((source) {
      if (_filter == _SourceFilter.recent && source.id != widget.selectedSourceId) {
        return false;
      }
      if (query.isEmpty) return true;
      return source.displayName.toLowerCase().contains(query);
    }).toList();
    final pinOrder = <String, int>{for (var index = 0; index < _pinnedSourceIds.length; index++) _pinnedSourceIds[index]: index};
    return visible..sort((left, right) {
      final leftOrder = pinOrder[left.id];
      final rightOrder = pinOrder[right.id];
      if (leftOrder == null && rightOrder == null) return 0;
      if (leftOrder == null) return 1;
      if (rightOrder == null) return -1;
      return leftOrder.compareTo(rightOrder);
    });
  }

  bool _isPinned(String sourceId) => _pinnedSourceIds.contains(sourceId);

  Future<void> _togglePinned(String sourceId) async {
    final pinned = !_isPinned(sourceId);
    final previous = List<String>.of(_pinnedSourceIds);
    setState(() {
      _pinnedSourceIds.remove(sourceId);
      if (pinned) _pinnedSourceIds.insert(0, sourceId);
    });
    try {
      await widget.onPinChanged?.call(sourceId, pinned);
    } on Object {
      if (!mounted) return;
      setState(() => _pinnedSourceIds = previous);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('置顶状态保存失败，请稍后重试。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final visibleSources = _visibleSources.toList(growable: false);
    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: 0.78,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
          ),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
            child: Column(
              children: <Widget>[
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: Stack(
                    alignment: Alignment.center,
                    children: <Widget>[
                      Text(
                        '选择数据源',
                        key: Key('discovery-source-picker-title'),
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      Positioned(
                        right: 22,
                        top: 12,
                        child: Semantics(
                          button: true,
                          label: '关闭',
                          child: GestureDetector(
                            key: const Key('discovery-source-picker-close'),
                            behavior: HitTestBehavior.opaque,
                            onTap: () => Navigator.of(context).pop(),
                            child: Icon(Icons.close_rounded, size: 20, color: Theme.of(context).colorScheme.onSurface),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.comfortable),
                  child: SizedBox(
                    height: 28,
                    child: TextField(
                      key: const Key('discovery-source-picker-search'),
                      onChanged: (value) => setState(() => _query = value),
                      style: Theme.of(context).textTheme.bodyMedium,
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        hintText: '搜索数据源',
                        hintStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
                        prefixIcon: IconTheme(
                          data: IconThemeData(color: tokens.mutedText, size: 18),
                          child: const Icon(Icons.search_rounded),
                        ),
                        prefixIconConstraints: const BoxConstraints(minWidth: 36),
                        filled: true,
                        fillColor: tokens.mutedSurface,
                        border: const OutlineInputBorder(borderRadius: AppRadii.pill, borderSide: BorderSide.none),
                        enabledBorder: const OutlineInputBorder(borderRadius: AppRadii.pill, borderSide: BorderSide.none),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: AppRadii.pill,
                          borderSide: BorderSide(color: tokens.accent),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.comfortable),
                  child: Row(
                    children: <Widget>[
                      for (final filter in _SourceFilter.values)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsetsDirectional.only(end: filter == _SourceFilter.recent ? 0 : AppSpacing.compact),
                            child: _SourceFilterButton(
                              label: switch (filter) {
                                _SourceFilter.all => '全部',
                                _SourceFilter.enabled => '已启用',
                                _SourceFilter.recent => '最近使用',
                              },
                              selected: _filter == filter,
                              onPressed: () => setState(() => _filter = filter),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: visibleSources.isEmpty
                      ? const Center(child: Text('没有匹配的数据源'))
                      : ListView.separated(
                          key: const Key('discovery-source-picker-list'),
                          padding: const EdgeInsets.fromLTRB(AppSpacing.comfortable, 0, AppSpacing.comfortable, 0),
                          itemCount: visibleSources.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 0.5),
                          itemBuilder: (context, index) {
                            final source = visibleSources[index];
                            return _SourcePickerRow(
                              source: source,
                              selected: source.id == widget.selectedSourceId,
                              pinned: _isPinned(source.id),
                              onPressed: () => Navigator.of(context).pop(DiscoverySourceSelected(source.id)),
                              onPinPressed: () => _togglePinned(source.id),
                              onWebViewAction: (action) =>
                                  Navigator.of(context).pop(DiscoverySourceWebViewActionRequested(sourceId: source.id, action: action)),
                            );
                          },
                        ),
                ),
                _SourcePickerFooter(onManagePressed: () => Navigator.of(context).pop(const DiscoverySourceManagementRequested())),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceFilterButton extends StatelessWidget {
  const _SourceFilterButton({required this.label, required this.selected, required this.onPressed});

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: '筛选数据源：$label',
      child: Material(
        color: selected ? tokens.accentSoft : tokens.mutedSurface,
        borderRadius: const BorderRadius.all(Radius.circular(7)),
        child: InkWell(
          onTap: onPressed,
          borderRadius: const BorderRadius.all(Radius.circular(7)),
          child: SizedBox(
            height: 22,
            child: Center(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: selected ? tokens.accent : tokens.mutedText,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
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
    return Semantics(
      button: true,
      selected: selected,
      label: '${pinned ? '已置顶' : '未置顶'}，选择来源：${source.displayName}',
      child: GestureDetector(
        onLongPressStart: (details) => _showSourcePickerActions(context, details.globalPosition, pinned, onPinPressed, onWebViewAction),
        onSecondaryTapUp: (details) => _showSourcePickerActions(context, details.globalPosition, pinned, onPinPressed, onWebViewAction),
        child: Material(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          child: InkWell(
            key: ValueKey<String>('discovery-source-picker-${source.id}'),
            onTap: onPressed,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            child: Container(
              height: 68,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.all(Radius.circular(8)),
                border: Border.all(color: selected ? tokens.accent.withValues(alpha: 0.35) : tokens.divider),
              ),
              child: Row(
                children: <Widget>[
                  SourceIcon(sourceId: source.id, displayName: source.displayName, iconUrl: source.iconUrl, size: 44, borderRadius: 9),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          source.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(height: 1.1, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          SourceBranding.description(sourceId: source.id, displayName: source.displayName, value: source.description),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText, height: 1.1),
                        ),
                      ],
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: pinned ? '取消置顶 ${source.displayName}' : '置顶 ${source.displayName}',
                    child: IconButton(
                      key: ValueKey<String>('discovery-source-picker-pin-${source.id}'),
                      tooltip: pinned ? '取消置顶' : '置顶',
                      onPressed: () => unawaited(onPinPressed()),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                      icon: Icon(
                        pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                        size: 18,
                        color: pinned ? tokens.accent : tokens.mutedText,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  _SourceSelectionIndicator(selected: selected),
                ],
              ),
            ),
          ),
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
    items: <PopupMenuEntry<_SourcePickerAction>>[
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
    ],
  );
  switch (action) {
    case _SourcePickerAction.togglePin:
      await onPinPressed();
    case _SourcePickerAction.enterDebug:
      onAction(DiscoverySourceWebViewAction.enterDebug);
    case _SourcePickerAction.show:
      onAction(DiscoverySourceWebViewAction.show);
    case null:
      return;
  }
}

enum _SourcePickerAction { togglePin, enterDebug, show }

class _SourceSelectionIndicator extends StatelessWidget {
  const _SourceSelectionIndicator({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return AnimatedContainer(
      duration: AppMotion.navigationSelection,
      width: 16,
      height: 16,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? tokens.accent : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(color: selected ? tokens.accent : tokens.mutedText.withValues(alpha: 0.72)),
      ),
      child: selected ? const Icon(Icons.check_rounded, size: 12, color: Colors.white) : null,
    );
  }
}

class _SourcePickerFooter extends StatelessWidget {
  const _SourcePickerFooter({required this.onManagePressed});

  final VoidCallback onManagePressed;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final textStyle = Theme.of(context).textTheme.titleMedium?.copyWith(color: tokens.accent);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: tokens.divider)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.symmetric(vertical: 4),
        child: SizedBox(
          height: 44,
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextButton.icon(
                  key: const Key('discovery-source-picker-manage'),
                  onPressed: onManagePressed,
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  label: const Text('管理数据源'),
                  style: TextButton.styleFrom(foregroundColor: tokens.accent, textStyle: textStyle),
                ),
              ),
              SizedBox(height: 22, child: VerticalDivider(color: tokens.divider)),
              Expanded(
                child: TextButton.icon(
                  key: const Key('discovery-source-picker-add'),
                  onPressed: onManagePressed,
                  icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
                  label: const Text('添加数据源'),
                  style: TextButton.styleFrom(foregroundColor: tokens.accent, textStyle: textStyle),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
