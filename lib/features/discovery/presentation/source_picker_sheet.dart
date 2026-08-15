import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

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
final class DiscoverySourceManagementRequested
    extends DiscoverySourcePickerResult {
  const DiscoverySourceManagementRequested();
}

/// Shows the discovery source picker without exposing Runtime installation data.
Future<DiscoverySourcePickerResult?> showDiscoverySourcePicker(
  BuildContext context, {
  required List<PluginSourceDescriptor> sources,
  required String selectedSourceId,
}) {
  return showModalBottomSheet<DiscoverySourcePickerResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _DiscoverySourcePickerSheet(
      sources: sources,
      selectedSourceId: selectedSourceId,
    ),
  );
}

enum _SourceFilter { all, enabled, current }

class _DiscoverySourcePickerSheet extends StatefulWidget {
  const _DiscoverySourcePickerSheet({
    required this.sources,
    required this.selectedSourceId,
  });

  final List<PluginSourceDescriptor> sources;
  final String selectedSourceId;

  @override
  State<_DiscoverySourcePickerSheet> createState() =>
      _DiscoverySourcePickerSheetState();
}

class _DiscoverySourcePickerSheetState
    extends State<_DiscoverySourcePickerSheet> {
  _SourceFilter _filter = _SourceFilter.all;
  String _query = '';

  Iterable<PluginSourceDescriptor> get _visibleSources {
    final query = _query.trim().toLowerCase();
    return widget.sources.where((source) {
      if (_filter == _SourceFilter.current &&
          source.id != widget.selectedSourceId) {
        return false;
      }
      if (query.isEmpty) return true;
      return source.displayName.toLowerCase().contains(query);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final visibleSources = _visibleSources.toList(growable: false);
    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: 0.82,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.section,
                AppSpacing.unit,
                AppSpacing.section,
                AppSpacing.compact,
              ),
              child: Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      '选择数据来源',
                      key: Key('discovery-source-picker-title'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('discovery-source-picker-close'),
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.section,
              ),
              child: TextField(
                key: const Key('discovery-source-picker-search'),
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: '搜索数据来源',
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled: true,
                  fillColor: tokens.mutedSurface,
                  border: OutlineInputBorder(
                    borderRadius: AppRadii.pill,
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: AppRadii.pill,
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: AppRadii.pill,
                    borderSide: BorderSide(color: tokens.accent),
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.regular),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.section,
              ),
              child: Row(
                children: <Widget>[
                  for (final filter in _SourceFilter.values)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          right: filter == _SourceFilter.current
                              ? 0
                              : AppSpacing.compact,
                        ),
                        child: _SourceFilterButton(
                          label: switch (filter) {
                            _SourceFilter.all => '全部',
                            _SourceFilter.enabled => '已启用',
                            _SourceFilter.current => '当前来源',
                          },
                          selected: _filter == filter,
                          onPressed: () => setState(() => _filter = filter),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.compact),
            Expanded(
              child: visibleSources.isEmpty
                  ? const Center(child: Text('没有匹配的数据来源'))
                  : ListView.separated(
                      key: const Key('discovery-source-picker-list'),
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.section,
                        AppSpacing.compact,
                        AppSpacing.section,
                        AppSpacing.section,
                      ),
                      itemCount: visibleSources.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: AppSpacing.compact),
                      itemBuilder: (context, index) {
                        final source = visibleSources[index];
                        return _SourcePickerRow(
                          source: source,
                          selected: source.id == widget.selectedSourceId,
                          onPressed: () => Navigator.of(
                            context,
                          ).pop(DiscoverySourceSelected(source.id)),
                        );
                      },
                    ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(top: BorderSide(color: tokens.divider)),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.section,
                  AppSpacing.regular,
                  AppSpacing.section,
                  AppSpacing.regular,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    key: const Key('discovery-source-picker-manage'),
                    onPressed: () => Navigator.of(
                      context,
                    ).pop(const DiscoverySourceManagementRequested()),
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('管理书源'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceFilterButton extends StatelessWidget {
  const _SourceFilterButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Material(
      color: selected ? tokens.accentSoft : tokens.mutedSurface,
      borderRadius: AppRadii.control,
      child: InkWell(
        onTap: onPressed,
        borderRadius: AppRadii.control,
        child: SizedBox(
          height: AppSpacing.sectionControlHeight,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: selected ? tokens.accent : tokens.mutedText,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
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
    required this.onPressed,
  });

  final PluginSourceDescriptor source;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final kinds = source.contentKinds
        .map((kind) => kind.name == 'novel' ? '小说' : '漫画')
        .join(' · ');
    return Semantics(
      button: true,
      selected: selected,
      label: '选择来源：${source.displayName}',
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: AppRadii.surface,
        child: InkWell(
          key: ValueKey<String>('discovery-source-picker-${source.id}'),
          onTap: onPressed,
          borderRadius: AppRadii.surface,
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.regular),
            decoration: BoxDecoration(
              borderRadius: AppRadii.surface,
              border: Border.all(
                color: selected ? tokens.accent : tokens.divider,
              ),
            ),
            child: Row(
              children: <Widget>[
                _SourceMonogram(name: source.displayName),
                const SizedBox(width: AppSpacing.regular),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        source.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: AppSpacing.unit),
                      Text(
                        '$kinds内容来源 · 已启用',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: tokens.mutedText,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? tokens.accent : tokens.mutedText,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceMonogram extends StatelessWidget {
  const _SourceMonogram({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final glyph = name.isEmpty ? '源' : name.characters.first;
    return Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tokens.accentSoft,
        borderRadius: AppRadii.control,
      ),
      child: Text(
        glyph,
        style: TextStyle(
          color: tokens.accent,
          fontSize: 22,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
