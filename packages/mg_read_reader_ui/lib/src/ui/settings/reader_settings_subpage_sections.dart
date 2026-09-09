/// 字体、间距、评论与更多设置子页区块及共享控件组合。
part of 'reader_settings_sheet.dart';

extension _ReaderSettingsSubpageSections on _ReaderSettingsSheetState {
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
        _buildFontSizeSlider(palette),
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
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 4),
            child: Text(
              ReaderStrings.externalFonts,
              style: TextStyle(
                color: palette.secondaryText,
                fontSize: ReaderSettingsTokens.subpageLabelFontSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(
            height: 248,
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
            _updateState(() => _autoReading = value);
            widget.onAutoReadingChanged(value);
          },
        ),
        _settingsChoice<ReaderAutoReadingPace>(
          title: ReaderStrings.autoReadingSpeed,
          values: ReaderAutoReadingPace.values,
          selected: _autoReadingPace,
          labelFor: (ReaderAutoReadingPace value) => switch (value) {
            ReaderAutoReadingPace.slow => ReaderStrings.slow,
            ReaderAutoReadingPace.normal => ReaderStrings.standard,
            ReaderAutoReadingPace.fast => ReaderStrings.fast,
          },
          onSelected: (ReaderAutoReadingPace value) {
            _updateState(() => _autoReadingPace = value);
            widget.onAutoReadingPaceChanged(value);
          },
          palette: palette,
        ),
        _settingsSwitch(
          title: ReaderStrings.singleHandMode,
          value: _preferences.singleHandMode,
          onChanged: (bool value) =>
              _commit(_preferences.copyWith(singleHandMode: value)),
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
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
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
                const SizedBox(height: 4),
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
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
            child: Text(
              title,
              style: TextStyle(
                color: palette.secondaryText,
                fontSize: ReaderSettingsTokens.controlTextSize,
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

  Widget _buildFontSizeSlider(ReaderPalette palette) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
            child: Text(
              ReaderStrings.fontSize,
              style: TextStyle(
                color: palette.secondaryText,
                fontSize: ReaderSettingsTokens.controlTextSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ReaderSettingsCapsule(
            palette: palette,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Slider(
                    value: _preferences.fontSize,
                    min: _fontSizeMin,
                    max: _fontSizeMax,
                    label: _preferences.fontSize.round().toString(),
                    semanticFormatterCallback: (double value) =>
                        '${ReaderStrings.fontSize} ${value.round()}',
                    onChanged: (double value) =>
                        _preview(_preferences.copyWith(fontSize: value)),
                    onChangeEnd: (double value) =>
                        _commit(_preferences.copyWith(fontSize: value)),
                  ),
                ),
                SizedBox(
                  width: 30,
                  child: Text(
                    _preferences.fontSize.round().toString(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
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
      title: Text(
        title,
        style: const TextStyle(
          fontSize: ReaderSettingsTokens.subpageLabelFontSize,
        ),
      ),
      value: value,
      onChanged: onChanged,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ReaderSettingsTokens.smallRadius),
      ),
    );
  }

  Widget _settingsChoice<T>({
    required String title,
    required List<T> values,
    required T selected,
    required String Function(T) labelFor,
    required ValueChanged<T> onSelected,
    required ReaderPalette palette,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: ReaderSettingsTokens.rowMinHeight,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: ReaderSettingsTokens.subpageLabelFontSize,
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: ReaderSettingsTokens.autoReadingSpeedControlWidth,
              child: ReaderSettingsSegmentedControl<T>(
                values: values,
                selected: selected,
                labelFor: labelFor,
                onSelected: onSelected,
                palette: palette,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
