/// 间距页的即时排版样张；只复用当前偏好，不读取正文或持久化。
/// 恢复默认仅影响字号、字重和间距，保留字体、纸张、亮度与翻页偏好。
part of 'reader_settings_sheet.dart';

extension _ReaderSettingsLayoutPreview on _ReaderSettingsSheetState {
  Widget _buildLayoutPreview(ReaderPalette palette) {
    final style = TextStyle(
      fontSize: _preferences.fontSize,
      height: _preferences.lineHeight,
      letterSpacing: _preferences.letterSpacing,
      fontWeight:
          FontWeight.values[(_preferences.fontWeight ~/ 100 - 1).clamp(0, 8)],
      color: palette.text,
    );
    final indent = '　' * _preferences.firstLineIndent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('排版预览'),
            TextButton(
              key: const ValueKey('reader-reset-layout'),
              onPressed: _resetLayout,
              child: const Text('恢复默认排版'),
            ),
          ],
        ),
        Container(
          key: const ValueKey('reader-layout-preview'),
          decoration: BoxDecoration(
            color: palette.background,
            borderRadius: BorderRadius.circular(
              ReaderSettingsTokens.smallRadius,
            ),
            border: Border.all(color: palette.divider),
          ),
          padding: EdgeInsets.symmetric(
            horizontal: _preferences.horizontalPadding,
            vertical: 12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('$indent风翻过书页，文字在纸上慢慢展开。', style: style),
              SizedBox(height: _preferences.paragraphSpacing),
              Text('$indent调节间距，找到舒适的阅读节奏。', style: style),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  void _resetLayout() {
    const defaults = TextReaderPreferences.defaults;
    _commit(
      _preferences.copyWith(
        fontSize: defaults.fontSize,
        fontWeight: defaults.fontWeight,
        letterSpacing: defaults.letterSpacing,
        lineHeight: defaults.lineHeight,
        paragraphSpacing: defaults.paragraphSpacing,
        firstLineIndent: defaults.firstLineIndent,
        horizontalPadding: defaults.horizontalPadding,
        topPadding: defaults.topPadding,
        bottomPadding: defaults.bottomPadding,
      ),
    );
  }
}
