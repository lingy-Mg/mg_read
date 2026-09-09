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
                const SizedBox(height: 2),
                _buildBackgroundRow(palette),
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
            width: ReaderSettingsTokens.eyeCareControlWidth,
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
    final String fontLabel = switch (_preferences.font) {
      ReaderFontPreset.system => ReaderStrings.miSans,
      ReaderFontPreset.sansSerif => ReaderStrings.sansSerif,
      ReaderFontPreset.serif => ReaderStrings.serif,
    };
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Widget sizeControl = _buildFontSizeSlider(palette);
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
              SizedBox(
                width: ReaderSettingsTokens.fontSizeControlWidth,
                child: sizeControl,
              ),
              const SizedBox(width: 6),
              SizedBox(
                width:
                    (constraints.maxWidth -
                            ReaderSettingsTokens.labelWidth -
                            ReaderSettingsTokens.fontSizeControlWidth -
                            6)
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
