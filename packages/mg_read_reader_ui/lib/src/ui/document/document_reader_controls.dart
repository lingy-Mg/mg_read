part of 'document_reader_view.dart';

extension _DocumentReaderControls on _DocumentReaderViewState {
  Future<void> _showReadingControls() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .75,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Text('字号'),
                      Expanded(
                        child: Slider(
                          min: 16,
                          max: 32,
                          divisions: 8,
                          value: _preferences.fontSize,
                          onChanged: (value) {
                            final next = _preferences.copyWith(fontSize: value);
                            _previewPreferences(next);
                            setSheetState(() {});
                          },
                          onChangeEnd: (value) => unawaited(
                            _changePreferences(
                              _preferences.copyWith(fontSize: value),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  DropdownButton<ReaderThemePreset>(
                    value: _preferences.theme,
                    isExpanded: true,
                    items: ReaderThemePreset.values
                        .map(
                          (theme) => DropdownMenuItem(
                            value: theme,
                            child: Text(_themeName(theme)),
                          ),
                        )
                        .toList(),
                    onChanged: (theme) {
                      if (theme != null) {
                        final next = _preferences.copyWith(theme: theme);
                        setSheetState(() {});
                        unawaited(_changePreferences(next));
                      }
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('使用书籍样式'),
                    subtitle: const Text('允许书籍设置字体大小、行距与颜色'),
                    value: _useBookStyles,
                    onChanged: (value) {
                      final anchor = _captureVisibleProgress() ?? _progress;
                      _setUseBookStyles(value);
                      setSheetState(() {});
                      if (anchor != null) _scheduleSemanticRestore(anchor);
                    },
                  ),
                  Row(
                    children: [
                      const Text('行距'),
                      Expanded(
                        child: Slider(
                          min: 1.5,
                          max: 2.1,
                          divisions: 2,
                          value: _preferences.lineHeight,
                          onChanged: (value) {
                            final next = _preferences.copyWith(
                              lineHeight: value,
                            );
                            _previewPreferences(next);
                            setSheetState(() {});
                          },
                          onChangeEnd: (value) => unawaited(
                            _changePreferences(
                              _preferences.copyWith(lineHeight: value),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _themeName(ReaderThemePreset theme) => switch (theme) {
    ReaderThemePreset.day => '日间',
    ReaderThemePreset.eyeCare => '护眼',
    ReaderThemePreset.parchment => '羊皮纸',
    ReaderThemePreset.night => '夜间',
    ReaderThemePreset.mistBlue => '雾蓝',
    ReaderThemePreset.deepNight => '深夜',
    ReaderThemePreset.charcoal => '炭灰',
    ReaderThemePreset.oled => '纯黑',
    ReaderThemePreset.midnight => '午夜',
    ReaderThemePreset.forestNight => '森林夜',
    ReaderThemePreset.lavenderMist => '淡紫',
    ReaderThemePreset.roseTea => '玫瑰茶',
    ReaderThemePreset.seaGlass => '海玻璃',
  };
}
