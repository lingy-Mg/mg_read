import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';

/// Two-section navigation for recently updated and shelf views.
class LibrarySectionNavigation extends StatelessWidget {
  /// Creates the section control with an explicit selected value.
  const LibrarySectionNavigation({
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final LibraryHomeSection selected;
  final ValueChanged<LibraryHomeSection> onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _SectionButton(
          label: '最近更新',
          section: LibraryHomeSection.recentUpdates,
          selected: selected,
          onSelected: onSelected,
        ),
        const SizedBox(width: AppSpacing.section + AppSpacing.unit),
        _SectionButton(
          label: '书架',
          section: LibraryHomeSection.shelf,
          selected: selected,
          onSelected: onSelected,
        ),
      ],
    );
  }
}

class _SectionButton extends StatelessWidget {
  const _SectionButton({
    required this.label,
    required this.section,
    required this.selected,
    required this.onSelected,
  });

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
      child: TextButton(
        onPressed: () => onSelected(section),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, AppSpacing.sectionControlHeight),
          foregroundColor: isSelected
              ? theme.colorScheme.onSurface
              : tokens.mutedText,
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              label,
              style: theme.textTheme.titleMedium?.copyWith(
                height: 1.15,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected ? null : tokens.mutedText,
              ),
            ),
            const SizedBox(height: AppSpacing.unit),
            AnimatedContainer(
              duration: kThemeAnimationDuration,
              height: 2,
              width: AppSpacing.section - AppSpacing.unit / 2,
              decoration: BoxDecoration(
                color: isSelected ? tokens.accent : Colors.transparent,
                borderRadius: AppRadii.pill,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Horizontally scrollable status filters with touch-safe hit targets.
class LibraryStatusFilterBar extends StatelessWidget {
  /// Creates the status filter control with a single selected filter.
  const LibraryStatusFilterBar({
    required this.selected,
    required this.onSelected,
    super.key,
  });

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
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List<Widget>.generate(
                      LibraryStatusFilter.values.length,
                      (int index) {
                        final LibraryStatusFilter filter =
                            LibraryStatusFilter.values[index];
                        return Padding(
                          padding: EdgeInsets.only(
                            left: index == 0 ? 0 : AppSpacing.compact,
                          ),
                          child: _FilterChip(
                            filter: filter,
                            selected: filter == selected,
                            onSelected: onSelected,
                          ),
                        );
                      },
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
  const _FilterChip({
    required this.filter,
    required this.selected,
    required this.onSelected,
  });

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
          height: AppSpacing.statusFilterHeight,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.compact - AppSpacing.unit / 2,
          ),
          decoration: ShapeDecoration(
            color: selected ? tokens.surface : tokens.mutedSurface,
            shape: StadiumBorder(
              side: BorderSide(
                color: selected ? tokens.accent : Colors.transparent,
              ),
            ),
          ),
          child: InkWell(
            onTap: () => onSelected(filter),
            borderRadius: AppRadii.pill,
            child: Center(
              child: ExcludeSemantics(
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w400,
                    height: 1,
                    color: selected ? tokens.warning : tokens.mutedText,
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
