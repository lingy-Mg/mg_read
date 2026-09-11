part of 'text_reader_view.dart';

/// 组合阅读器根背景、输入、系统样式和覆盖层。
///
/// 固定背景与正文分属不同重绘边界；只有覆盖/仿真翻页把背景交给移动页片。
extension _TextReaderRootWidgets on _TextReaderViewState {
  Widget _buildReaderRoot(BuildContext context) {
    final ReaderPalette palette = _palette;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value:
          (palette.systemBrightness == Brightness.dark
                  ? SystemUiOverlayStyle.light
                  : SystemUiOverlayStyle.dark)
              .copyWith(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: Colors.transparent,
                systemNavigationBarDividerColor: Colors.transparent,
                systemStatusBarContrastEnforced: false,
                systemNavigationBarContrastEnforced: false,
              ),
      child: Theme(
        data: _readerMaterialTheme(palette),
        child: PopScope<void>(
          canPop: true,
          onPopInvokedWithResult: (bool didPop, void result) {
            if (didPop) unawaited(_requestExit());
          },
          child: Material(
            color: palette.background,
            child: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                    unawaited(_nextPage()),
                const SingleActivator(LogicalKeyboardKey.pageDown): () =>
                    unawaited(_nextPage()),
                const SingleActivator(LogicalKeyboardKey.space): () =>
                    unawaited(_nextPage()),
                const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                    unawaited(_previousPage()),
                const SingleActivator(LogicalKeyboardKey.pageUp): () =>
                    unawaited(_previousPage()),
                const SingleActivator(
                  LogicalKeyboardKey.space,
                  shift: true,
                ): () =>
                    unawaited(_previousPage()),
                const SingleActivator(LogicalKeyboardKey.escape): () =>
                    unawaited(_requestExit()),
              },
              child: Focus(
                focusNode: _focusNode,
                autofocus: true,
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    _ensurePagination(constraints.biggest);
                    return ScrollConfiguration(
                      behavior: const _ReaderScrollBehavior(),
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          _buildReaderContentSurface(palette),
                          if (_horizontalChapterHandoff != null)
                            _buildHorizontalChapterHandoff(
                              _horizontalChapterHandoff!,
                            ),
                          if (_controlsVisible && !_readerSettingsVisible)
                            _buildControlsInteractionLock(),
                          if (_content != null) _buildChrome(),
                          if (_readerSettingsVisible)
                            _buildSettingsInteractionLock(),
                          if (_awaitingPreviousChapterTail)
                            _PreviousChapterTailMask(palette: palette),
                          if (_chapterLoadingOverlayVisible)
                            _ChapterLoadingMask(palette: palette),
                          if (_noticeMessage != null)
                            _ReaderNotice(message: _noticeMessage!),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReaderContentSurface(ReaderPalette palette) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (_movingPageOwnsBackground)
          ColoredBox(color: palette.background)
        else
          RepaintBoundary(
            key: const ValueKey<String>('reader-fixed-background'),
            child: ReaderBackgroundSurface(
              preset: _preferences.background,
              palette: palette,
            ),
          ),
        _buildContent(),
        IgnorePointer(
          child: ColoredBox(
            color: Colors.black.withValues(
              alpha: (1 - _preferences.brightness) * 0.65,
            ),
          ),
        ),
      ],
    );
  }
}
