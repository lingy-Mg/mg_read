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
    isDismissible: true,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.30),
    elevation: 0,
    builder: (context) => _DiscoverySourcePickerSheet(
      sources: sources,
      selectedSourceId: selectedSourceId,
    ),
  );
}

enum _SourceFilter { all, enabled, recent }

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
      if (_filter == _SourceFilter.recent &&
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
                      const Text(
                        '选择数据来源',
                        key: Key('discovery-source-picker-title'),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
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
                            child: Icon(
                              Icons.close_rounded,
                              size: 20,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.comfortable,
                  ),
                  child: SizedBox(
                    height: 28,
                    child: TextField(
                      key: const Key('discovery-source-picker-search'),
                      onChanged: (value) => setState(() => _query = value),
                      style: Theme.of(context).textTheme.bodyMedium,
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        hintText: '搜索数据来源',
                        hintStyle: Theme.of(context).textTheme.bodyLarge
                            ?.copyWith(color: tokens.mutedText, fontSize: 12),
                        prefixIcon: IconTheme(
                          data: IconThemeData(
                            color: tokens.mutedText,
                            size: 18,
                          ),
                          child: const Icon(Icons.search_rounded),
                        ),
                        prefixIconConstraints: const BoxConstraints(
                          minWidth: 36,
                        ),
                        filled: true,
                        fillColor: tokens.mutedSurface,
                        border: const OutlineInputBorder(
                          borderRadius: AppRadii.pill,
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: const OutlineInputBorder(
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
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.comfortable,
                  ),
                  child: Row(
                    children: <Widget>[
                      for (final filter in _SourceFilter.values)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsetsDirectional.only(
                              end: filter == _SourceFilter.recent
                                  ? 0
                                  : AppSpacing.compact,
                            ),
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
                      ? const Center(child: Text('没有匹配的数据来源'))
                      : ListView.separated(
                          key: const Key('discovery-source-picker-list'),
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.comfortable,
                            0,
                            AppSpacing.comfortable,
                            0,
                          ),
                          itemCount: visibleSources.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 0.5),
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
                _SourcePickerFooter(
                  onManagePressed: () => Navigator.of(
                    context,
                  ).pop(const DiscoverySourceManagementRequested()),
                ),
              ],
            ),
          ),
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
    return Semantics(
      button: true,
      selected: selected,
      label: '筛选数据来源：$label',
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
                style: TextStyle(
                  color: selected ? tokens.accent : tokens.mutedText,
                  fontSize: 12,
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
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        child: InkWell(
          key: ValueKey<String>('discovery-source-picker-${source.id}'),
          onTap: onPressed,
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          child: Container(
            height: 37,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(8)),
              border: Border.all(
                color: selected
                    ? tokens.accent.withValues(alpha: 0.35)
                    : tokens.divider,
              ),
            ),
            child: Row(
              children: <Widget>[
                _SourceMonogram(source: source),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const SizedBox(height: 4),
                      Text(
                        source.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontSize: 12,
                          height: 1.1,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        _sourceSubtitle(source, kinds),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: tokens.mutedText,
                          fontSize: 9,
                          height: 1.05,
                        ),
                      ),
                    ],
                  ),
                ),
                _SourceSelectionIndicator(selected: selected),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceMonogram extends StatelessWidget {
  const _SourceMonogram({required this.source});

  final PluginSourceDescriptor source;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final _SourceMark mark = _sourceMark(source.displayName, tokens);
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[mark.color, mark.color.withValues(alpha: 0.72)],
        ),
        borderRadius: const BorderRadius.all(Radius.circular(6)),
      ),
      child: Text(
        mark.glyph,
        style: TextStyle(
          color: Colors.white,
          fontSize: mark.glyph.length > 1 ? 11 : 16,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String _sourceSubtitle(PluginSourceDescriptor source, String kinds) =>
    switch (source.displayName) {
      '起点中文网' => '阅文集团旗下原创文学平台',
      '番茄小说' => '今日头条旗下免费小说平台',
      '七猫中文网' => '海量正版小说，永久免费阅读',
      '纵横中文网' => '精品原创小说阅读平台',
      '晋江文学城' => '女性向原创文学网站',
      '17K 小说网' => '中文在线旗下阅读平台',
      '潇湘书院' => '专注女性原创小说平台',
      '飞卢小说网' => '原创小说首发网站',
      '豆瓣阅读' => '优质原创作品阅读平台',
      '书旗小说' => '阿里文学旗下阅读平台',
      '刺猬猫阅读' => '二次元小说阅读平台',
      '掌阅精选' => '掌阅科技旗下阅读平台',
      _ => '$kinds内容来源 · 已启用',
    };

_SourceMark _sourceMark(String name, AppThemeTokens tokens) {
  return switch (name) {
    '起点中文网' => _SourceMark(tokens.notification, '起'),
    '番茄小说' => _SourceMark(tokens.warning, '番'),
    '七猫中文网' => _SourceMark(tokens.warning, '猫'),
    '纵横中文网' => _SourceMark(tokens.notification, '纵'),
    '晋江文学城' => _SourceMark(tokens.success, '晋'),
    '17K 小说网' => _SourceMark(tokens.accent, '17K'),
    '潇湘书院' => _SourceMark(tokens.coverIndigoEnd, '潇'),
    '飞卢小说网' => _SourceMark(tokens.success, '飞'),
    '豆瓣阅读' => _SourceMark(tokens.coverOceanEnd, '豆'),
    '书旗小说' => _SourceMark(tokens.success, '书'),
    '刺猬猫阅读' => _SourceMark(tokens.warning, '猫'),
    '掌阅精选' => _SourceMark(tokens.coverDawnEnd, '阅'),
    _ => _SourceMark(tokens.accent, name.isEmpty ? '源' : name.characters.first),
  };
}

class _SourceMark {
  const _SourceMark(this.color, this.glyph);

  final Color color;
  final String glyph;
}

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
        border: Border.all(
          color: selected
              ? tokens.accent
              : tokens.mutedText.withValues(alpha: 0.72),
        ),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, size: 12, color: Colors.white)
          : null,
    );
  }
}

class _SourcePickerFooter extends StatelessWidget {
  const _SourcePickerFooter({required this.onManagePressed});

  final VoidCallback onManagePressed;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final textStyle = Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(color: tokens.accent);
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
                  style: TextButton.styleFrom(
                    foregroundColor: tokens.accent,
                    textStyle: textStyle?.copyWith(fontSize: 12),
                  ),
                ),
              ),
              SizedBox(
                height: 22,
                child: VerticalDivider(color: tokens.divider),
              ),
              Expanded(
                child: TextButton.icon(
                  key: const Key('discovery-source-picker-add'),
                  onPressed: onManagePressed,
                  icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
                  label: const Text('添加数据源'),
                  style: TextButton.styleFrom(
                    foregroundColor: tokens.accent,
                    textStyle: textStyle?.copyWith(fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
