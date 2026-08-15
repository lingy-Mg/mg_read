import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/contracts.dart';
import '../../api/models.dart';
import '../../core/auto_reading_coordinator.dart';
import '../../platform/reader_platform.dart';
import '../reader_strings.dart';
import '../reader_theme.dart';
import '../fonts/reader_font_catalog.dart';
import 'reader_settings_controls.dart';
import 'reader_settings_tokens.dart';

Future<void> showReaderSettingsSheet({
  required BuildContext context,
  required TextReaderPreferences preferences,
  required ReaderPalette palette,
  required ReaderPlatformCapabilities platformCapabilities,
  required bool commentsAvailable,
  required bool autoReading,
  required ReaderAutoReadingPace autoReadingPace,
  required ReaderThemePreset lastNonNightTheme,
  required ReaderFontRepository? fontRepository,
  required FutureOr<void> Function(
    ReaderFontDescriptor descriptor,
    String runtimeFamily,
  )
  onCustomFontSelected,
  required ValueChanged<Object> onFontError,
  required ValueChanged<TextReaderPreferences> onPreferencesPreview,
  required ValueChanged<TextReaderPreferences> onPreferencesCommit,
  required ValueChanged<bool> onAutoReadingChanged,
  required ValueChanged<ReaderAutoReadingPace> onAutoReadingPaceChanged,
  required VoidCallback onCatalogPressed,
  required VoidCallback onBookmarksPressed,
  VoidCallback? onDismissed,
}) {
  TextReaderPreferences latestPreferences = preferences.normalized();
  bool hasPendingPreview = false;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    useSafeArea: false,
    backgroundColor: Colors.transparent,
    barrierColor: ReaderSettingsTokens.sheetBarrier(palette),
    builder: (BuildContext context) {
      final double height =
          (MediaQuery.sizeOf(context).height *
                  ReaderSettingsTokens.sheetHeightFactor)
              .clamp(0, ReaderSettingsTokens.maxDesktopSheetHeight)
              .toDouble();
      // Keep the route child limited to the visible sheet. A full-height Align
      // would cover the modal barrier with a transparent BottomSheet surface,
      // preventing outside taps from dismissing the sheet.
      return SizedBox(
        width: double.infinity,
        height: height,
        child: ReaderSettingsSheet(
          preferences: preferences,
          palette: palette,
          platformCapabilities: platformCapabilities,
          commentsAvailable: commentsAvailable,
          autoReading: autoReading,
          autoReadingPace: autoReadingPace,
          lastNonNightTheme: lastNonNightTheme,
          fontRepository: fontRepository,
          onCustomFontSelected: onCustomFontSelected,
          onFontError: onFontError,
          onPreferencesPreview: (TextReaderPreferences value) {
            latestPreferences = value.normalized();
            hasPendingPreview = true;
            onPreferencesPreview(latestPreferences);
          },
          onPreferencesCommit: (TextReaderPreferences value) {
            latestPreferences = value.normalized();
            hasPendingPreview = false;
            onPreferencesCommit(latestPreferences);
          },
          onAutoReadingChanged: onAutoReadingChanged,
          onAutoReadingPaceChanged: onAutoReadingPaceChanged,
          onCatalogPressed: onCatalogPressed,
          onBookmarksPressed: onBookmarksPressed,
        ),
      );
    },
  ).whenComplete(() {
    // A route can be dismissed while a Slider gesture is still active. Flush
    // exactly its latest preview rather than losing it or persisting every
    // intermediate drag value.
    if (hasPendingPreview) onPreferencesCommit(latestPreferences);
    onDismissed?.call();
  });
}

class ReaderSettingsSheet extends StatefulWidget {
  const ReaderSettingsSheet({
    super.key,
    required this.preferences,
    required this.palette,
    required this.platformCapabilities,
    required this.commentsAvailable,
    required this.autoReading,
    required this.autoReadingPace,
    required this.lastNonNightTheme,
    required this.fontRepository,
    required this.onCustomFontSelected,
    required this.onFontError,
    required this.onPreferencesPreview,
    required this.onPreferencesCommit,
    required this.onAutoReadingChanged,
    required this.onAutoReadingPaceChanged,
    required this.onCatalogPressed,
    required this.onBookmarksPressed,
  });

  final TextReaderPreferences preferences;
  final ReaderPalette palette;
  final ReaderPlatformCapabilities platformCapabilities;
  final bool commentsAvailable;
  final bool autoReading;
  final ReaderAutoReadingPace autoReadingPace;
  final ReaderThemePreset lastNonNightTheme;
  final ReaderFontRepository? fontRepository;
  final FutureOr<void> Function(
    ReaderFontDescriptor descriptor,
    String runtimeFamily,
  )
  onCustomFontSelected;
  final ValueChanged<Object> onFontError;
  final ValueChanged<TextReaderPreferences> onPreferencesPreview;
  final ValueChanged<TextReaderPreferences> onPreferencesCommit;
  final ValueChanged<bool> onAutoReadingChanged;
  final ValueChanged<ReaderAutoReadingPace> onAutoReadingPaceChanged;
  final VoidCallback onCatalogPressed;
  final VoidCallback onBookmarksPressed;

  @override
  State<ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

enum _SettingsPage { main, font, spacing, comments, more }

enum _PagingChoice { pageCurl, cover, slide, vertical, none }

class _ReaderSettingsSheetState extends State<ReaderSettingsSheet> {
  static const List<double> _fontSizes = <double>[16, 19, 22, 26, 32];

  late TextReaderPreferences _preferences;
  late ReaderAutoReadingPace _autoReadingPace;
  late bool _autoReading;
  ReaderThemePreset _lastNonNightTheme = ReaderThemePreset.day;
  _SettingsPage _page = _SettingsPage.main;

  ReaderPalette get _palette => ReaderPalette.fromPreset(_preferences.theme);

  @override
  void initState() {
    super.initState();
    _preferences = widget.preferences.normalized();
    _autoReading = widget.autoReading;
    _autoReadingPace = widget.autoReadingPace;
    _lastNonNightTheme = _isNightTheme(widget.lastNonNightTheme)
        ? ReaderThemePreset.day
        : widget.lastNonNightTheme;
    if (!_isNightTheme(_preferences.theme)) {
      _lastNonNightTheme = _preferences.theme;
    }
  }

  @override
  void didUpdateWidget(covariant ReaderSettingsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.preferences != oldWidget.preferences) {
      _preferences = widget.preferences.normalized();
    }
    if (widget.autoReading != oldWidget.autoReading) {
      _autoReading = widget.autoReading;
    }
    if (widget.autoReadingPace != oldWidget.autoReadingPace) {
      _autoReadingPace = widget.autoReadingPace;
    }
  }

  void _preview(TextReaderPreferences next) {
    final TextReaderPreferences normalized = next.normalized();
    setState(() => _preferences = normalized);
    widget.onPreferencesPreview(normalized);
  }

  void _commit(TextReaderPreferences next) {
    final TextReaderPreferences normalized = next.normalized();
    if (!_isNightTheme(normalized.theme)) {
      _lastNonNightTheme = normalized.theme;
    }
    if (_preferences != normalized) {
      setState(() => _preferences = normalized);
      widget.onPreferencesPreview(normalized);
    }
    widget.onPreferencesCommit(normalized);
  }

  void _openPage(_SettingsPage page) => setState(() => _page = page);

  @override
  Widget build(BuildContext context) {
    final ReaderPalette palette = _palette;
    final MediaQueryData mediaQuery = MediaQuery.of(context);
    final ThemeData theme = Theme.of(context).copyWith(
      brightness: palette.systemBrightness,
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: palette.accent,
            brightness: palette.systemBrightness,
          ).copyWith(
            primary: palette.accent,
            surface: palette.panel,
            onSurface: palette.text,
            outline: palette.divider,
          ),
      textTheme: Theme.of(
        context,
      ).textTheme.apply(bodyColor: palette.text, displayColor: palette.text),
      iconTheme: IconThemeData(color: palette.text),
    );
    return MediaQuery(
      data: mediaQuery.copyWith(
        textScaler: mediaQuery.textScaler.clamp(maxScaleFactor: 1.3),
      ),
      child: Theme(
        data: theme,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: ReaderSettingsTokens.maxSheetWidth,
            ),
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(ReaderSettingsTokens.sheetRadius),
              ),
              child: Material(
                color: palette.panel,
                child: SafeArea(
                  top: false,
                  child: Column(
                    children: <Widget>[
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: ReaderSettingsTokens.transitionDuration,
                          child: KeyedSubtree(
                            key: ValueKey<_SettingsPage>(_page),
                            child: switch (_page) {
                              _SettingsPage.main => _buildMainPage(palette),
                              _SettingsPage.font => _buildFontPage(palette),
                              _SettingsPage.spacing => _buildSpacingPage(
                                palette,
                              ),
                              _SettingsPage.comments => _buildCommentsPage(
                                palette,
                              ),
                              _SettingsPage.more => _buildMorePage(palette),
                            },
                          ),
                        ),
                      ),
                      ReaderSettingsBottomNavigation(
                        palette: palette,
                        nightSelected: _isNightTheme(_preferences.theme),
                        onCatalogPressed: widget.onCatalogPressed,
                        onNightPressed: _toggleNight,
                        onSettingsPressed: () => _openPage(_SettingsPage.main),
                        onBookmarksPressed: widget.onBookmarksPressed,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMainPage(ReaderPalette palette) {
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          ReaderSettingsTokens.contentHorizontalPadding,
          ReaderSettingsTokens.contentVerticalPadding,
          ReaderSettingsTokens.contentHorizontalPadding,
          10,
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: ReaderSettingsTokens.maxContentWidth,
            ),
            child: Column(
              children: <Widget>[
                _buildBrightnessRow(palette),
                const SizedBox(height: 4),
                _buildFontSizeRow(palette),
                const SizedBox(height: 4),
                _buildThemeRow(palette),
                const SizedBox(height: 4),
                _buildBackgroundRow(palette),
                const SizedBox(height: 6),
                _buildPagingRow(palette),
                const SizedBox(height: 6),
                _buildOtherRow(palette),
                const SizedBox(height: 6),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(
                      0,
                      ReaderSettingsTokens.touchTarget,
                    ),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                  onPressed: _toggleAutoReading,
                  icon: Icon(
                    _autoReading
                        ? Icons.pause_circle_outline_rounded
                        : Icons.play_arrow_rounded,
                    size: 19,
                  ),
                  label: Text(
                    _autoReading
                        ? ReaderStrings.stopAutoReading
                        : ReaderStrings.startAutoReading,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBrightnessRow(ReaderPalette palette) {
    return ReaderSettingsSectionRow(
      label: ReaderStrings.brightness,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Slider(
              value: _preferences.brightness,
              min: .25,
              max: 1,
              divisions: 30,
              label: '${(_preferences.brightness * 100).round()}%',
              semanticFormatterCallback: (double value) =>
                  '${ReaderStrings.brightness} ${(value * 100).round()}%',
              onChanged: (double value) =>
                  _preview(_preferences.copyWith(brightness: value)),
              onChangeEnd: (double value) =>
                  _commit(_preferences.copyWith(brightness: value)),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 108,
            child: ReaderSettingsCapsule(
              palette: palette,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              selected: _preferences.theme == ReaderThemePreset.eyeCare,
              semanticLabel: ReaderStrings.eyeCareMode,
              onTap: () => _commit(
                _preferences.copyWith(theme: ReaderThemePreset.eyeCare),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(ReaderStrings.eyeCareMode),
                  SizedBox(width: 4),
                  Icon(Icons.visibility_outlined, size: 17),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFontSizeRow(ReaderPalette palette) {
    final int sizeIndex = _fontSizes.indexOf(_preferences.fontSize);
    final String fontLabel = switch (_preferences.font) {
      ReaderFontPreset.system => ReaderStrings.miSans,
      ReaderFontPreset.sansSerif => ReaderStrings.sansSerif,
      ReaderFontPreset.serif => ReaderStrings.serif,
    };
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Widget sizeControl = ReaderSettingsCapsule(
          palette: palette,
          padding: EdgeInsets.zero,
          child: Row(
            children: <Widget>[
              Expanded(
                child: IconButton(
                  tooltip: ReaderStrings.decreaseFontSize,
                  onPressed: sizeIndex > 0
                      ? () => _commit(
                          _preferences.copyWith(
                            fontSize: _fontSizes[sizeIndex - 1],
                          ),
                        )
                      : null,
                  icon: const Icon(Icons.text_decrease_rounded),
                ),
              ),
              SizedBox(
                width: 32,
                child: Text(
                  _preferences.fontSize.round().toString(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Expanded(
                child: IconButton(
                  tooltip: ReaderStrings.increaseFontSize,
                  onPressed: sizeIndex < _fontSizes.length - 1
                      ? () => _commit(
                          _preferences.copyWith(
                            fontSize: _fontSizes[sizeIndex + 1],
                          ),
                        )
                      : null,
                  icon: const Icon(Icons.text_increase_rounded),
                ),
              ),
            ],
          ),
        );
        final Widget fontControl = ReaderSettingsCapsule(
          palette: palette,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          onTap: () => _openPage(_SettingsPage.font),
          semanticLabel: ReaderStrings.selectFont,
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  fontLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        );
        if (constraints.maxWidth < 300) {
          return ReaderSettingsSectionRow(
            label: ReaderStrings.fontSize,
            alignTop: true,
            child: Column(
              children: <Widget>[
                sizeControl,
                const SizedBox(height: 6),
                fontControl,
              ],
            ),
          );
        }
        return ReaderSettingsSectionRow(
          label: ReaderStrings.fontSize,
          child: Row(
            children: <Widget>[
              SizedBox(width: 136, child: sizeControl),
              const SizedBox(width: 6),
              SizedBox(
                width:
                    (constraints.maxWidth -
                            ReaderSettingsTokens.labelWidth -
                            142)
                        .clamp(96, 220)
                        .toDouble(),
                child: fontControl,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildThemeRow(ReaderPalette palette) {
    return ReaderSettingsSectionRow(
      label: ReaderStrings.color,
      child: SizedBox(
        height: ReaderSettingsTokens.touchTarget,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _themeOrder.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (BuildContext context, int index) {
            final ReaderThemePreset preset = _themeOrder[index];
            return ReaderThemeSwatch(
              preset: preset,
              selected: preset == _preferences.theme,
              label: _themeLabel(preset),
              onTap: () => _commit(_preferences.copyWith(theme: preset)),
            );
          },
        ),
      ),
    );
  }

  Widget _buildBackgroundRow(ReaderPalette palette) {
    return ReaderSettingsSectionRow(
      label: ReaderStrings.background,
      alignTop: true,
      child: SizedBox(
        height: ReaderSettingsTokens.touchTarget,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: ReaderBackgroundPreset.values.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (BuildContext context, int index) {
            final ReaderBackgroundPreset preset =
                ReaderBackgroundPreset.values[index];
            return ReaderBackgroundChoice(
              preset: preset,
              palette: palette,
              selected: preset == _preferences.background,
              label: _backgroundLabel(preset),
              onTap: () => _commit(_preferences.copyWith(background: preset)),
            );
          },
        ),
      ),
    );
  }

  Widget _buildPagingRow(ReaderPalette palette) {
    return ReaderSettingsSectionRow(
      label: ReaderStrings.paging,
      child: ReaderSettingsSegmentedControl<_PagingChoice>(
        values: _PagingChoice.values,
        selected: _selectedPagingChoice,
        labelFor: _pagingLabel,
        onSelected: _updatePaging,
        palette: palette,
      ),
    );
  }

  Widget _buildOtherRow(ReaderPalette palette) {
    return ReaderSettingsSectionRow(
      label: ReaderStrings.other,
      alignTop: true,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          const double spacing = 6;
          final int actionCount = widget.commentsAvailable ? 3 : 2;
          final double actionWidth =
              (constraints.maxWidth - spacing * (actionCount - 1)) /
              actionCount;
          Widget action({
            required String label,
            required VoidCallback onTap,
            Widget? trailing,
          }) {
            return SizedBox(
              width: actionWidth,
              child: ReaderSettingsCapsule(
                palette: palette,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                onTap: onTap,
                semanticLabel: label,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    ?trailing,
                  ],
                ),
              ),
            );
          }

          return Row(
            mainAxisAlignment: MainAxisAlignment.start,
            spacing: spacing,
            children: <Widget>[
              action(
                label: ReaderStrings.spacingSettings,
                onTap: () => _openPage(_SettingsPage.spacing),
              ),
              if (widget.commentsAvailable)
                action(
                  label: ReaderStrings.commentSettings,
                  onTap: () => _openPage(_SettingsPage.comments),
                ),
              action(
                label: ReaderStrings.moreSettings,
                onTap: () => _openPage(_SettingsPage.more),
                trailing: const Icon(Icons.chevron_right_rounded, size: 17),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFontPage(ReaderPalette palette) {
    return _subpage(
      header: ReaderSettingsSubpageHeader(
        title: ReaderStrings.typography,
        onBack: () => _openPage(_SettingsPage.main),
        palette: palette,
      ),
      children: <Widget>[
        _labeledChoice<ReaderFontPreset>(
          ReaderStrings.typography,
          ReaderFontPreset.values,
          _preferences.font,
          (ReaderFontPreset value) => switch (value) {
            ReaderFontPreset.system => ReaderStrings.miSans,
            ReaderFontPreset.sansSerif => ReaderStrings.sansSerif,
            ReaderFontPreset.serif => ReaderStrings.serif,
          },
          (ReaderFontPreset value) => _commit(
            _preferences.copyWith(font: value, clearCustomFontId: true),
          ),
          palette,
        ),
        _labeledChoice<double>(
          ReaderStrings.fontSize,
          _fontSizes,
          _preferences.fontSize,
          (double value) => value.round().toString(),
          (double value) => _commit(_preferences.copyWith(fontSize: value)),
          palette,
        ),
        _labeledChoice<int>(
          ReaderStrings.fontWeight,
          const <int>[400, 500, 600],
          _preferences.fontWeight,
          (int value) => value == 400
              ? ReaderStrings.regular
              : value == 500
              ? ReaderStrings.medium
              : ReaderStrings.bold,
          (int value) => _commit(_preferences.copyWith(fontWeight: value)),
          palette,
        ),
        _labeledChoice<double>(
          ReaderStrings.letterSpacing,
          const <double>[0, .2, .8],
          _preferences.letterSpacing,
          (double value) => value == 0
              ? ReaderStrings.compact
              : value == .2
              ? ReaderStrings.standard
              : ReaderStrings.relaxed,
          (double value) =>
              _commit(_preferences.copyWith(letterSpacing: value)),
          palette,
        ),
        if (widget.fontRepository != null) ...<Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 5),
            child: Text(
              ReaderStrings.externalFonts,
              style: TextStyle(
                color: palette.secondaryText,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(
            height: 300,
            child: ReaderFontCatalog(
              repository: widget.fontRepository!,
              palette: palette,
              selectedFontId: _preferences.customFontId,
              onSelected: _handleCustomFontSelected,
              onError: widget.onFontError,
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _handleCustomFontSelected(
    ReaderFontDescriptor descriptor,
    String runtimeFamily,
  ) async {
    await widget.onCustomFontSelected(descriptor, runtimeFamily);
    if (!mounted) return;
    _commit(_preferences.copyWith(customFontId: descriptor.id));
  }

  Widget _buildSpacingPage(ReaderPalette palette) {
    return _subpage(
      header: ReaderSettingsSubpageHeader(
        title: ReaderStrings.spacingSettings,
        onBack: () => _openPage(_SettingsPage.main),
        palette: palette,
      ),
      children: <Widget>[
        _labeledChoice<double>(
          ReaderStrings.lineHeight,
          const <double>[1.5, 1.8, 2.1],
          _preferences.lineHeight,
          _threeLevelLabel,
          (double value) => _commit(_preferences.copyWith(lineHeight: value)),
          palette,
        ),
        _labeledChoice<double>(
          ReaderStrings.paragraphSpacing,
          const <double>[8, 14, 22],
          _preferences.paragraphSpacing,
          _threeLevelLabel,
          (double value) =>
              _commit(_preferences.copyWith(paragraphSpacing: value)),
          palette,
        ),
        _labeledChoice<int>(
          ReaderStrings.firstLineIndent,
          const <int>[0, 1, 2],
          _preferences.firstLineIndent,
          (int value) => value == 0
              ? ReaderStrings.none
              : value == 1
              ? ReaderStrings.oneCharacter
              : ReaderStrings.twoCharacters,
          (int value) => _commit(_preferences.copyWith(firstLineIndent: value)),
          palette,
        ),
        _labeledChoice<double>(
          ReaderStrings.pageMargin,
          const <double>[16, 24, 40],
          _preferences.horizontalPadding,
          (double value) => value == 16
              ? ReaderStrings.narrow
              : value == 24
              ? ReaderStrings.standard
              : ReaderStrings.wide,
          (double value) =>
              _commit(_preferences.copyWith(horizontalPadding: value)),
          palette,
        ),
        _labeledChoice<double>(
          ReaderStrings.topMargin,
          const <double>[8, 24, 40, 64],
          _preferences.topPadding,
          (double value) => value.round().toString(),
          (double value) => _commit(_preferences.copyWith(topPadding: value)),
          palette,
        ),
        _labeledChoice<double>(
          ReaderStrings.bottomMargin,
          const <double>[8, 24, 40, 64],
          _preferences.bottomPadding,
          (double value) => value.round().toString(),
          (double value) =>
              _commit(_preferences.copyWith(bottomPadding: value)),
          palette,
        ),
      ],
    );
  }

  Widget _buildCommentsPage(ReaderPalette palette) {
    return _subpage(
      header: ReaderSettingsSubpageHeader(
        title: ReaderStrings.commentSettings,
        subtitle: widget.commentsAvailable
            ? ReaderStrings.readOnlyCommentsHint
            : ReaderStrings.commentsUnavailable,
        onBack: () => _openPage(_SettingsPage.main),
        palette: palette,
      ),
      children: widget.commentsAvailable
          ? <Widget>[
              _settingsSwitch(
                title: ReaderStrings.displayBookComments,
                value: _preferences.showBookComments,
                onChanged: (bool value) =>
                    _commit(_preferences.copyWith(showBookComments: value)),
              ),
              _settingsSwitch(
                title: ReaderStrings.displayChapterComments,
                value: _preferences.showChapterComments,
                onChanged: (bool value) =>
                    _commit(_preferences.copyWith(showChapterComments: value)),
              ),
              _settingsSwitch(
                title: ReaderStrings.displayParagraphComments,
                value: _preferences.showParagraphComments,
                onChanged: (bool value) => _commit(
                  _preferences.copyWith(showParagraphComments: value),
                ),
              ),
            ]
          : <Widget>[
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  ReaderStrings.commentsUnavailable,
                  style: TextStyle(color: palette.secondaryText),
                ),
              ),
            ],
    );
  }

  Widget _buildMorePage(ReaderPalette palette) {
    return _subpage(
      header: ReaderSettingsSubpageHeader(
        title: ReaderStrings.moreSettings,
        onBack: () => _openPage(_SettingsPage.main),
        palette: palette,
      ),
      children: <Widget>[
        _settingsSwitch(
          title: ReaderStrings.autoReading,
          value: _autoReading,
          onChanged: (bool value) {
            setState(() => _autoReading = value);
            widget.onAutoReadingChanged(value);
          },
        ),
        _labeledChoice<ReaderAutoReadingPace>(
          ReaderStrings.autoReadingSpeed,
          ReaderAutoReadingPace.values,
          _autoReadingPace,
          (ReaderAutoReadingPace value) => switch (value) {
            ReaderAutoReadingPace.slow => ReaderStrings.slow,
            ReaderAutoReadingPace.normal => ReaderStrings.standard,
            ReaderAutoReadingPace.fast => ReaderStrings.fast,
          },
          (ReaderAutoReadingPace value) {
            setState(() => _autoReadingPace = value);
            widget.onAutoReadingPaceChanged(value);
          },
          palette,
        ),
        if (widget.platformCapabilities.keepScreenOn)
          _settingsSwitch(
            title: ReaderStrings.keepScreenOn,
            value: _preferences.keepScreenOn,
            onChanged: (bool value) =>
                _commit(_preferences.copyWith(keepScreenOn: value)),
          ),
        if (widget.platformCapabilities.immersiveMode)
          _settingsSwitch(
            title: ReaderStrings.immersiveReading,
            value: _preferences.immersiveMode,
            onChanged: (bool value) =>
                _commit(_preferences.copyWith(immersiveMode: value)),
          ),
      ],
    );
  }

  Widget _subpage({required Widget header, required List<Widget> children}) {
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: ReaderSettingsTokens.maxContentWidth,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                header,
                const SizedBox(height: 8),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _labeledChoice<T>(
    String title,
    List<T> values,
    T selected,
    String Function(T) labelFor,
    ValueChanged<T> onSelected,
    ReaderPalette palette,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 5),
            child: Text(
              title,
              style: TextStyle(
                color: palette.secondaryText,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ReaderSettingsSegmentedControl<T>(
            values: values,
            selected: selected,
            labelFor: labelFor,
            onSelected: onSelected,
            palette: palette,
          ),
        ],
      ),
    );
  }

  Widget _settingsSwitch({
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -4),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      value: value,
      onChanged: onChanged,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ReaderSettingsTokens.smallRadius),
      ),
    );
  }

  void _toggleNight() {
    final ReaderThemePreset next = _isNightTheme(_preferences.theme)
        ? _lastNonNightTheme
        : ReaderThemePreset.night;
    _commit(_preferences.copyWith(theme: next));
  }

  void _toggleAutoReading() {
    setState(() => _autoReading = !_autoReading);
    widget.onAutoReadingChanged(_autoReading);
  }

  _PagingChoice get _selectedPagingChoice {
    if (_preferences.navigationMode == ReaderNavigationMode.verticalScroll) {
      return _PagingChoice.vertical;
    }
    return switch (_preferences.pageAnimation) {
      ReaderPageAnimation.pageCurl => _PagingChoice.pageCurl,
      ReaderPageAnimation.cover => _PagingChoice.cover,
      ReaderPageAnimation.slide => _PagingChoice.slide,
      ReaderPageAnimation.none => _PagingChoice.none,
    };
  }

  void _updatePaging(_PagingChoice choice) {
    final TextReaderPreferences next = switch (choice) {
      _PagingChoice.vertical => _preferences.copyWith(
        navigationMode: ReaderNavigationMode.verticalScroll,
      ),
      _PagingChoice.pageCurl => _preferences.copyWith(
        navigationMode: ReaderNavigationMode.horizontalPages,
        pageAnimation: ReaderPageAnimation.pageCurl,
      ),
      _PagingChoice.cover => _preferences.copyWith(
        navigationMode: ReaderNavigationMode.horizontalPages,
        pageAnimation: ReaderPageAnimation.cover,
      ),
      _PagingChoice.slide => _preferences.copyWith(
        navigationMode: ReaderNavigationMode.horizontalPages,
        pageAnimation: ReaderPageAnimation.slide,
      ),
      _PagingChoice.none => _preferences.copyWith(
        navigationMode: ReaderNavigationMode.horizontalPages,
        pageAnimation: ReaderPageAnimation.none,
      ),
    };
    _commit(next);
  }

  String _pagingLabel(_PagingChoice choice) => switch (choice) {
    _PagingChoice.pageCurl => ReaderStrings.pageCurl,
    _PagingChoice.cover => ReaderStrings.cover,
    _PagingChoice.slide => ReaderStrings.slide,
    _PagingChoice.vertical => ReaderStrings.verticalPaging,
    _PagingChoice.none => ReaderStrings.noAnimation,
  };

  String _themeLabel(ReaderThemePreset preset) => switch (preset) {
    ReaderThemePreset.day => ReaderStrings.day,
    ReaderThemePreset.eyeCare => ReaderStrings.eyeCare,
    ReaderThemePreset.parchment => ReaderStrings.parchment,
    ReaderThemePreset.night => ReaderStrings.night,
    ReaderThemePreset.mistBlue => ReaderStrings.mistBlue,
    ReaderThemePreset.deepNight => ReaderStrings.deepNight,
    ReaderThemePreset.charcoal => ReaderStrings.charcoal,
  };

  String _backgroundLabel(ReaderBackgroundPreset preset) => switch (preset) {
    ReaderBackgroundPreset.plain => ReaderStrings.plainBackground,
    ReaderBackgroundPreset.softPaper => ReaderStrings.softPaperBackground,
    ReaderBackgroundPreset.ricePaper => ReaderStrings.ricePaperBackground,
    ReaderBackgroundPreset.clouds => ReaderStrings.cloudsBackground,
    ReaderBackgroundPreset.mistMountains =>
      ReaderStrings.mistMountainsBackground,
    ReaderBackgroundPreset.distantLandscape =>
      ReaderStrings.distantLandscapeBackground,
  };

  String _threeLevelLabel(double value) => value == 1.5 || value == 8
      ? ReaderStrings.compact
      : value == 1.8 || value == 14
      ? ReaderStrings.standard
      : ReaderStrings.relaxed;

  static const List<ReaderThemePreset> _themeOrder = <ReaderThemePreset>[
    ReaderThemePreset.day,
    ReaderThemePreset.parchment,
    ReaderThemePreset.eyeCare,
    ReaderThemePreset.mistBlue,
    ReaderThemePreset.night,
    ReaderThemePreset.deepNight,
    ReaderThemePreset.charcoal,
  ];

  bool _isNightTheme(ReaderThemePreset theme) =>
      theme == ReaderThemePreset.night ||
      theme == ReaderThemePreset.deepNight ||
      theme == ReaderThemePreset.charcoal;
}
