/// 设置主页面的亮度、字号、配色、背景、翻页与快捷入口区块。
part of 'reader_settings_sheet.dart';

extension _ReaderSettingsMainSections on _ReaderSettingsSheetState {
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
                const SizedBox(height: 2),
                _buildFontSizeRow(palette),
                const SizedBox(height: 2),
                _buildThemeRow(palette),
                _selectedPaperLabel(
                  '当前：${_themeLabel(_preferences.theme)}',
                  palette,
                ),
                const SizedBox(height: 2),
                _buildBackgroundRow(palette),
                _selectedPaperLabel(
                  '当前：${_backgroundLabel(_preferences.background)}',
                  palette,
                ),
                const SizedBox(height: 4),
                _buildPagingRow(palette),
                const SizedBox(height: 4),
                _buildOtherRow(palette),
                const SizedBox(height: 2),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(
                      0,
                      ReaderSettingsTokens.touchTarget,
                    ),
                    textStyle: const TextStyle(
                      fontSize: ReaderSettingsTokens.subpageLabelFontSize,
                    ),
                  ),
                  onPressed: _toggleAutoReading,
                  icon: Icon(
                    _autoReading
                        ? Icons.pause_circle_outline_rounded
                        : Icons.play_arrow_rounded,
                    size: 17,
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

  Widget _selectedPaperLabel(String label, ReaderPalette palette) => Padding(
    padding: const EdgeInsets.only(
      left: ReaderSettingsTokens.labelWidth,
      bottom: 4,
    ),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: TextStyle(
          fontSize: ReaderSettingsTokens.controlTextSize,
          color: palette.secondaryText,
        ),
      ),
    ),
  );

  Widget _buildBrightnessRow(ReaderPalette palette) {
    return ReaderSettingsSectionRow(
      label: ReaderStrings.brightness,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Slider(
              key: const ValueKey<String>('reader-settings-brightness-slider'),
              value: _preferences.brightness,
              min: .05,
              max: 1,
              divisions: 38,
              label: _preferences.brightnessMode == ReaderBrightnessMode.system
                  ? ReaderStrings.systemBrightness
                  : '${(_preferences.brightness * 100).round()}%',
              semanticFormatterCallback: (double value) =>
                  _preferences.brightnessMode == ReaderBrightnessMode.system
                  ? ReaderStrings.systemBrightness
                  : '${ReaderStrings.brightness} ${(value * 100).round()}%',
              onChanged:
                  _preferences.brightnessMode == ReaderBrightnessMode.manual
                  ? (double value) =>
                        _preview(_preferences.copyWith(brightness: value))
                  : null,
              onChangeEnd:
                  _preferences.brightnessMode == ReaderBrightnessMode.manual
                  ? (double value) =>
                        _commit(_preferences.copyWith(brightness: value))
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: ReaderSettingsTokens.brightnessModeControlWidth,
            child: ReaderSettingsSegmentedControl<ReaderBrightnessMode>(
              key: const ValueKey<String>('reader-settings-brightness-mode'),
              values: const <ReaderBrightnessMode>[
                ReaderBrightnessMode.manual,
                ReaderBrightnessMode.system,
              ],
              selected: _preferences.brightnessMode,
              labelFor: (ReaderBrightnessMode mode) => switch (mode) {
                ReaderBrightnessMode.manual => ReaderStrings.manualBrightness,
                ReaderBrightnessMode.system => ReaderStrings.systemBrightness,
              },
              onSelected: (ReaderBrightnessMode mode) =>
                  _commit(_preferences.copyWith(brightnessMode: mode)),
              palette: palette,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFontSizeRow(ReaderPalette palette) {
    final String fontLabel = switch (_preferences.font) {
      ReaderFontPreset.system => ReaderStrings.miSans,
      ReaderFontPreset.sansSerif => ReaderStrings.sansSerif,
      ReaderFontPreset.serif => ReaderStrings.serif,
    };
    final Widget sizeControl = _buildFontSizeControl(
      palette,
      showProgress: false,
      showLabel: false,
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
          const Icon(Icons.chevron_right_rounded, size: 18),
        ],
      ),
    );
    return ReaderSettingsSectionRow(
      label: ReaderStrings.fontSize,
      child: Row(
        children: <Widget>[
          Expanded(child: sizeControl),
          const SizedBox(width: 6),
          Expanded(child: fontControl),
        ],
      ),
    );
  }

  Widget _buildThemeRow(ReaderPalette palette) {
    return ReaderSettingsSectionRow(
      label: ReaderStrings.color,
      child: SizedBox(
        height: ReaderSettingsTokens.touchTarget,
        child: ReaderSettingsHorizontalList(
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
        child: ReaderSettingsHorizontalList(
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
}
