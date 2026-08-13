import 'package:flutter/material.dart';

import 'package:mg_read/app/app_strings.dart';
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
          label: AppStrings.recentUpdatesLabel,
          section: LibraryHomeSection.recentUpdates,
          selected: selected,
          onSelected: onSelected,
        ),
        const SizedBox(width: AppSpacing.regular),
        _SectionButton(
          label: AppStrings.shelfLabel,
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
          minimumSize: const Size(0, AppSpacing.minimumTouchTarget),
          foregroundColor: isSelected ? tokens.accent : tokens.mutedText,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.compact),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              label,
              style: theme.textTheme.titleMedium?.copyWith(
                color: isSelected ? null : tokens.mutedText,
              ),
            ),
            const SizedBox(height: AppSpacing.compact),
            AnimatedContainer(
              duration: kThemeAnimationDuration,
              height: AppSpacing.unit,
              width: AppSpacing.section,
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
      label: AppStrings.statusFilterLabel,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: LibraryStatusFilter.values
              .map(
                (LibraryStatusFilter filter) => Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.compact),
                  child: _FilterChip(
                    filter: filter,
                    selected: filter == selected,
                    onSelected: onSelected,
                  ),
                ),
              )
              .toList(growable: false),
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
      child: SizedBox(
        height: AppSpacing.minimumTouchTarget,
        child: Center(
          child: ChoiceChip(
            label: Text(label, style: theme.textTheme.bodyMedium),
            selected: selected,
            onSelected: (_) => onSelected(filter),
            selectedColor: tokens.accentSoft,
            backgroundColor: tokens.mutedSurface,
            side: BorderSide(color: selected ? tokens.accent : tokens.divider),
            shape: const StadiumBorder(),
          ),
        ),
      ),
    );
  }

  String _labelFor(LibraryStatusFilter filter) {
    return switch (filter) {
      LibraryStatusFilter.all => AppStrings.filterAllLabel,
      LibraryStatusFilter.ongoing => AppStrings.filterOngoingLabel,
      LibraryStatusFilter.completed => AppStrings.filterCompletedLabel,
      LibraryStatusFilter.local => AppStrings.filterLocalLabel,
    };
  }
}
