/// 设置路由、预览、提交与自动阅读状态协调器。
///
/// 不访问宿主 IO；所有持久化仍通过公开回调提交。
part of 'reader_settings_sheet.dart';

class _ReaderSettingsSheetState extends State<ReaderSettingsSheet> {
  late TextReaderPreferences _preferences;
  late ReaderAutoReadingPace _autoReadingPace;
  late bool _autoReading;
  late bool _layoutDebugMode;
  _SettingsPage _page = _SettingsPage.main;

  ReaderPalette get _palette => ReaderPalette.fromPreset(_preferences.theme);

  @override
  void initState() {
    super.initState();
    _preferences = widget.preferences.normalized();
    _autoReading = widget.autoReading;
    _autoReadingPace = widget.autoReadingPace;
    _layoutDebugMode = widget.layoutDebugMode;
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
    if (widget.layoutDebugMode != oldWidget.layoutDebugMode) {
      _layoutDebugMode = widget.layoutDebugMode;
    }
  }

  void _preview(TextReaderPreferences next) {
    final TextReaderPreferences normalized = next.normalized();
    setState(() => _preferences = normalized);
    widget.onPreferencesPreview(normalized);
  }

  void _commit(TextReaderPreferences next) {
    final TextReaderPreferences normalized = next.normalized();
    if (_preferences != normalized) {
      setState(() => _preferences = normalized);
      widget.onPreferencesPreview(normalized);
    }
    widget.onPreferencesCommit(normalized);
  }

  void _adjustFontSize(double delta) {
    _commit(_preferences.copyWith(fontSize: _preferences.fontSize + delta));
  }

  void _openPage(_SettingsPage page) => setState(() => _page = page);

  void _updateState(VoidCallback update) => setState(update);

  @override
  Widget build(BuildContext context) {
    final ReaderPalette palette = _palette;
    final MediaQueryData mediaQuery = MediaQuery.of(context);
    final ThemeData theme = readerThemeData(palette, font: _preferences.font);
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
            child: SizedBox(
              width: double.infinity,
              height: double.infinity,
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
                            duration: ReaderSettingsTokens.effectiveDuration(
                              context,
                            ),
                            layoutBuilder:
                                (
                                  Widget? currentChild,
                                  List<Widget> previousChildren,
                                ) => Stack(
                                  alignment: Alignment.topCenter,
                                  children: <Widget>[
                                    ...previousChildren,
                                    ?currentChild,
                                  ],
                                ),
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
                          onSettingsPressed: () =>
                              _openPage(_SettingsPage.main),
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
      ),
    );
  }

  void _toggleNight() {
    final ReaderThemePreset next = _isNightTheme(_preferences.theme)
        ? _preferences.lastNonNightTheme
        : _preferences.lastNightTheme;
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
    ReaderThemePreset.oled => ReaderStrings.oled,
    ReaderThemePreset.midnight => ReaderStrings.midnight,
    ReaderThemePreset.forestNight => ReaderStrings.forestNight,
    ReaderThemePreset.lavenderMist => ReaderStrings.lavenderMist,
    ReaderThemePreset.roseTea => ReaderStrings.roseTea,
    ReaderThemePreset.seaGlass => ReaderStrings.seaGlass,
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

  bool _isNightTheme(ReaderThemePreset theme) =>
      theme == ReaderThemePreset.night ||
      theme == ReaderThemePreset.deepNight ||
      theme == ReaderThemePreset.charcoal ||
      theme == ReaderThemePreset.oled ||
      theme == ReaderThemePreset.midnight ||
      theme == ReaderThemePreset.forestNight;
}
