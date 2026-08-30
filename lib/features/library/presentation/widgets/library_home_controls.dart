/// 首页书架分区与状态筛选控件。
///
/// 职责：
/// - 在同一视觉节奏中呈现最近阅读、书架和状态筛选。
/// - 通过显式回调更新首页局部选择，不拥有书架数据。
///
/// 注意：
/// - 窄屏状态筛选保持单行横向滚动，不压缩或换行。
///
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';

/// Two-section navigation for recently updated and shelf views.
class LibrarySectionNavigation extends StatelessWidget {
  /// Creates the section control with an explicit selected value.
  const LibrarySectionNavigation({required this.selected, required this.onSelected, super.key});

  final LibraryHomeSection selected;
  final ValueChanged<LibraryHomeSection> onSelected;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.mutedSurface.withValues(alpha: 0.78),
        borderRadius: AppRadii.pill,
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _SectionButton(label: '最近阅读', section: LibraryHomeSection.recentUpdates, selected: selected, onSelected: onSelected),
            _SectionButton(label: '书架', section: LibraryHomeSection.shelf, selected: selected, onSelected: onSelected),
          ],
        ),
      ),
    );
  }
}

class _SectionButton extends StatelessWidget {
  const _SectionButton({required this.label, required this.section, required this.selected, required this.onSelected});

  final String label;
  final LibraryHomeSection section;
  final LibraryHomeSection selected;
  final ValueChanged<LibraryHomeSection> onSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final bool isSelected = section == selected;

    return Semantics(
      button: true,
      selected: isSelected,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onSelected(section),
          borderRadius: AppRadii.pill,
          child: AnimatedContainer(
            duration: kThemeAnimationDuration,
            height: AppSpacing.sectionControlHeight - AppSpacing.unit,
            constraints: const BoxConstraints(minWidth: 48),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.compact),
            decoration: BoxDecoration(
              color: isSelected ? tokens.surface : Colors.transparent,
              borderRadius: AppRadii.pill,
              boxShadow: isSelected
                  ? <BoxShadow>[BoxShadow(color: tokens.shadow.withValues(alpha: 0.08), blurRadius: 6, offset: const Offset(0, 2))]
                  : null,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    height: 1.1,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    color: isSelected ? tokens.warning : tokens.mutedText,
                  ),
                ),
                Positioned(
                  bottom: 2,
                  child: AnimatedContainer(
                    duration: kThemeAnimationDuration,
                    width: isSelected ? AppSpacing.comfortable : 0,
                    height: 2,
                    decoration: BoxDecoration(color: tokens.accent, borderRadius: AppRadii.pill),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Horizontally scrollable status filters with touch-safe hit targets.
class LibraryStatusFilterBar extends StatelessWidget {
  /// Creates the status filter control with a single selected filter.
  const LibraryStatusFilterBar({required this.selected, required this.onSelected, super.key});

  final LibraryStatusFilter selected;
  final ValueChanged<LibraryStatusFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '书籍状态筛选',
      child: SizedBox(
        key: const Key('library-status-filter-bar'),
        height: AppSpacing.sectionControlHeight,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppThemeTokens.of(context).mutedSurface.withValues(alpha: 0.62),
                      borderRadius: AppRadii.pill,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          for (final LibraryStatusFilter filter in LibraryStatusFilter.values)
                            _FilterChip(filter: filter, selected: filter == selected, onSelected: onSelected),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.filter, required this.selected, required this.onSelected});

  final LibraryStatusFilter filter;
  final bool selected;
  final ValueChanged<LibraryStatusFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final String label = _labelFor(filter);

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      key: ValueKey<String>('library-filter-${filter.name}'),
      child: Material(
        color: Colors.transparent,
        child: Ink(
          height: AppSpacing.sectionControlHeight - AppSpacing.unit,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.compact),
          decoration: ShapeDecoration(
            color: selected ? tokens.accentSoft : Colors.transparent,
            shape: StadiumBorder(side: BorderSide(color: selected ? tokens.accent.withValues(alpha: 0.22) : Colors.transparent)),
          ),
          child: InkWell(
            onTap: () => onSelected(filter),
            borderRadius: AppRadii.pill,
            child: Center(
              child: ExcludeSemantics(
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    height: 1,
                    color: selected ? tokens.accent : tokens.mutedText,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _labelFor(LibraryStatusFilter filter) {
    return switch (filter) {
      LibraryStatusFilter.all => '全部',
      LibraryStatusFilter.ongoing => '连载',
      LibraryStatusFilter.completed => '完结',
      LibraryStatusFilter.local => '本地',
    };
  }
}
