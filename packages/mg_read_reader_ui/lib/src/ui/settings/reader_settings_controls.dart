import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../reader_strings.dart';
import '../reader_theme.dart';
import 'reader_settings_tokens.dart';

class ReaderSettingsSectionRow extends StatelessWidget {
  const ReaderSettingsSectionRow({
    super.key,
    required this.label,
    required this.child,
    this.alignTop = false,
  });

  final String label;
  final Widget child;
  final bool alignTop;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: ReaderSettingsTokens.rowMinHeight,
      ),
      child: Row(
        crossAxisAlignment: alignTop
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: ReaderSettingsTokens.labelWidth,
            child: Padding(
              padding: EdgeInsets.only(top: alignTop ? 9 : 0),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class ReaderSettingsCapsule extends StatelessWidget {
  const ReaderSettingsCapsule({
    super.key,
    required this.child,
    required this.palette,
    this.onTap,
    this.selected = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
    this.semanticLabel,
  });

  final Widget child;
  final ReaderPalette palette;
  final VoidCallback? onTap;
  final bool selected;
  final EdgeInsetsGeometry padding;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final Widget result = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(
        ReaderSettingsTokens.controlRadius + 4,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(
          ReaderSettingsTokens.controlRadius + 4,
        ),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: ReaderSettingsTokens.controlHeight,
          ),
          child: Stack(
            fit: StackFit.passthrough,
            children: <Widget>[
              Positioned.fill(
                top: 2,
                bottom: 2,
                child: Ink(
                  decoration: BoxDecoration(
                    color: selected
                        ? ReaderSettingsTokens.selectedControl(palette)
                        : ReaderSettingsTokens.mutedControl(palette),
                    borderRadius: BorderRadius.circular(
                      ReaderSettingsTokens.controlRadius,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: padding,
                child: Center(
                  child: DefaultTextStyle.merge(
                    style: const TextStyle(fontSize: 13),
                    child: child,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return semanticLabel == null
        ? result
        : Semantics(
            label: semanticLabel,
            button: onTap != null,
            selected: selected,
            onTap: onTap,
            excludeSemantics: true,
            child: result,
          );
  }
}

class ReaderSettingsSegmentedControl<T> extends StatelessWidget {
  const ReaderSettingsSegmentedControl({
    super.key,
    required this.values,
    required this.selected,
    required this.labelFor,
    required this.onSelected,
    required this.palette,
  });

  final List<T> values;
  final T selected;
  final String Function(T) labelFor;
  final ValueChanged<T> onSelected;
  final ReaderPalette palette;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double itemWidth = ((constraints.maxWidth - 6) / values.length)
            .clamp(48, 132)
            .toDouble();
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            constraints: BoxConstraints(
              minWidth: constraints.maxWidth,
              minHeight: ReaderSettingsTokens.controlHeight,
            ),
            decoration: BoxDecoration(
              color: ReaderSettingsTokens.mutedControl(palette),
              borderRadius: BorderRadius.circular(
                ReaderSettingsTokens.controlRadius,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Row(
              children: values
                  .map((T value) {
                    final bool isSelected = value == selected;
                    return SizedBox(
                      width: itemWidth,
                      height: ReaderSettingsTokens.touchTarget,
                      child: Semantics(
                        button: true,
                        selected: isSelected,
                        label: labelFor(value),
                        onTap: () => onSelected(value),
                        excludeSemantics: true,
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(
                            ReaderSettingsTokens.controlRadius,
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(
                              ReaderSettingsTokens.controlRadius,
                            ),
                            onTap: () => onSelected(value),
                            child: Center(
                              child: AnimatedContainer(
                                duration:
                                    ReaderSettingsTokens.transitionDuration,
                                height: 40,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? palette.panel
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(
                                    ReaderSettingsTokens.controlRadius - 2,
                                  ),
                                ),
                                child: Text(
                                  labelFor(value),
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isSelected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: isSelected
                                        ? palette.text
                                        : palette.secondaryText,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  })
                  .toList(growable: false),
            ),
          ),
        );
      },
    );
  }
}

class ReaderThemeSwatch extends StatelessWidget {
  const ReaderThemeSwatch({
    super.key,
    required this.preset,
    required this.selected,
    required this.label,
    required this.onTap,
  });

  final ReaderThemePreset preset;
  final bool selected;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ReaderPalette palette = ReaderPalette.fromPreset(preset);
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        onTap: onTap,
        excludeSemantics: true,
        child: InkResponse(
          onTap: onTap,
          radius: ReaderSettingsTokens.touchTarget / 2,
          child: SizedBox.square(
            dimension: ReaderSettingsTokens.touchTarget,
            child: Center(
              child: AnimatedContainer(
                duration: ReaderSettingsTokens.transitionDuration,
                width: ReaderSettingsTokens.swatchSize,
                height: ReaderSettingsTokens.swatchSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: palette.background,
                  border: Border.all(
                    width: selected
                        ? ReaderSettingsTokens.selectedBorderWidth
                        : 1,
                    color: selected ? palette.text : palette.divider,
                  ),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .06),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: selected
                    ? Icon(Icons.check_rounded, size: 17, color: palette.text)
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ReaderBackgroundChoice extends StatelessWidget {
  const ReaderBackgroundChoice({
    super.key,
    required this.preset,
    required this.palette,
    required this.selected,
    required this.label,
    required this.onTap,
  });

  final ReaderBackgroundPreset preset;
  final ReaderPalette palette;
  final bool selected;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        onTap: onTap,
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(ReaderSettingsTokens.smallRadius),
          onTap: onTap,
          child: SizedBox(
            width: ReaderSettingsTokens.backgroundPreviewWidth + 4,
            height: ReaderSettingsTokens.touchTarget,
            child: Center(
              child: AnimatedContainer(
                duration: ReaderSettingsTokens.transitionDuration,
                width: ReaderSettingsTokens.backgroundPreviewWidth,
                height: ReaderSettingsTokens.backgroundPreviewHeight,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    ReaderSettingsTokens.smallRadius,
                  ),
                  border: Border.all(
                    width: selected
                        ? ReaderSettingsTokens.selectedBorderWidth
                        : 1,
                    color: selected ? palette.text : palette.divider,
                  ),
                ),
                child: ReaderBackgroundSurface(
                  preset: preset,
                  palette: palette,
                  child: selected
                      ? Align(
                          alignment: Alignment.topRight,
                          child: Container(
                            margin: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: palette.panel.withValues(alpha: .9),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.check_rounded,
                              size: 14,
                              color: palette.text,
                            ),
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ReaderSettingsSubpageHeader extends StatelessWidget {
  const ReaderSettingsSubpageHeader({
    super.key,
    required this.title,
    required this.onBack,
    required this.palette,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final VoidCallback onBack;
  final ReaderPalette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        IconButton(
          tooltip: ReaderStrings.back,
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: TextStyle(color: palette.secondaryText, fontSize: 11),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class ReaderSettingsBottomNavigation extends StatelessWidget {
  const ReaderSettingsBottomNavigation({
    super.key,
    required this.palette,
    required this.nightSelected,
    required this.onCatalogPressed,
    required this.onNightPressed,
    required this.onSettingsPressed,
    required this.onBookmarksPressed,
  });

  final ReaderPalette palette;
  final bool nightSelected;
  final VoidCallback onCatalogPressed;
  final VoidCallback onNightPressed;
  final VoidCallback onSettingsPressed;
  final VoidCallback onBookmarksPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: ReaderSettingsTokens.navHeight,
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(top: BorderSide(color: palette.divider)),
      ),
      child: Row(
        children: <Widget>[
          _NavigationItem(
            icon: Icons.menu_book_outlined,
            label: ReaderStrings.catalog,
            onTap: onCatalogPressed,
            palette: palette,
          ),
          _NavigationItem(
            icon: nightSelected
                ? Icons.nightlight_rounded
                : Icons.nightlight_outlined,
            label: ReaderStrings.night,
            onTap: onNightPressed,
            selected: nightSelected,
            palette: palette,
          ),
          _NavigationItem(
            icon: Icons.tune_rounded,
            label: ReaderStrings.settings,
            onTap: onSettingsPressed,
            selected: true,
            palette: palette,
          ),
          _NavigationItem(
            icon: Icons.bookmarks_outlined,
            label: ReaderStrings.bookmarks,
            onTap: onBookmarksPressed,
            palette: palette,
          ),
        ],
      ),
    );
  }
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.palette,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final ReaderPalette palette;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final Color color = selected ? palette.text : palette.secondaryText;
    return Expanded(
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: Semantics(
          button: true,
          selected: selected,
          label: label,
          onTap: onTap,
          excludeSemantics: true,
          child: InkWell(
            onTap: onTap,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(icon, size: 22, color: color),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontSize: 10,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
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
}
