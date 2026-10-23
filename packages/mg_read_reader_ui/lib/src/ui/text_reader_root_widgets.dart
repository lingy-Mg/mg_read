part of 'text_reader_view.dart';

const double _readerPageFooterDebugHeight = 16;

/// 组合阅读器根背景、输入、系统样式和覆盖层。
///
/// 固定背景与正文分属不同重绘边界；只有覆盖/仿真翻页把背景交给移动页片。
extension _TextReaderRootWidgets on _TextReaderViewState {
  void _handleVolumeKey(ReaderVolumeKey key) {
    if (!_preferences.pageTurnShortcuts ||
        _readerInteractionBlocked ||
        !_foreground ||
        _content == null) {
      return;
    }
    unawaited(key == ReaderVolumeKey.down ? _nextPage() : _previousPage());
  }

  Widget _buildReaderRoot(BuildContext context) {
    final ReaderPalette palette = _palette;
    final Map<ShortcutActivator, VoidCallback> shortcuts =
        <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              unawaited(_requestExit()),
        };
    if (_preferences.pageTurnShortcuts) {
      shortcuts.addAll(<ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            unawaited(_nextPage()),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            unawaited(_nextPage()),
        const SingleActivator(LogicalKeyboardKey.pageDown): () =>
            unawaited(_nextPage()),
        const SingleActivator(LogicalKeyboardKey.space): () =>
            unawaited(_nextPage()),
        const SingleActivator(LogicalKeyboardKey.audioVolumeDown): () =>
            unawaited(_nextPage()),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            unawaited(_previousPage()),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            unawaited(_previousPage()),
        const SingleActivator(LogicalKeyboardKey.pageUp): () =>
            unawaited(_previousPage()),
        const SingleActivator(LogicalKeyboardKey.space, shift: true): () =>
            unawaited(_previousPage()),
        const SingleActivator(LogicalKeyboardKey.audioVolumeUp): () =>
            unawaited(_previousPage()),
      });
    }
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
        data: readerThemeData(palette, font: _preferences.font),
        child: PopScope<void>(
          canPop: true,
          onPopInvokedWithResult: (bool didPop, void result) {
            if (didPop) unawaited(_requestExit());
          },
          child: Material(
            color: palette.background,
            child: CallbackShortcuts(
              bindings: shortcuts,
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
                          if (_layoutDebugMode)
                            _buildLayoutDebugOverlay(context),
                          if (_controlsVisible && !_readerSettingsVisible)
                            _buildControlsInteractionLock(),
                          if (_content != null) _buildChrome(),
                          if (_readerSettingsVisible)
                            _buildSettingsInteractionLock(),
                          if (_awaitingPreviousChapterTail)
                            _PreviousChapterTailMask(palette: palette),
                          if (_chapterLoadingOverlayVisible)
                            _ChapterLoadingMask(palette: palette),
                          if (_retryChapterLoad != null && !_changingChapter)
                            _ChapterLoadFailureMask(
                              palette: palette,
                              message: _failure!.message,
                              onRetry: _retryFailedChapter,
                              onDismiss: _dismissChapterLoadFailure,
                            ),
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
      ],
    );
  }

  Widget _buildLayoutDebugOverlay(BuildContext context) {
    final MediaQueryData mediaQuery = MediaQuery.of(context);
    final double topInset = mediaQuery.padding.top;
    final double bottomInset = mediaQuery.padding.bottom;
    final double topPadding = _preferences.topPadding;
    final double bottomPadding = _preferences.bottomPadding;
    final double horizontalPadding = _preferences.horizontalPadding;
    final double contentTop = topInset + topPadding;
    final double contentBottom =
        mediaQuery.size.height - bottomInset - bottomPadding;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          CustomPaint(
            key: const ValueKey<String>('reader-layout-debug-overlay'),
            painter: _ReaderLayoutDebugPainter(
              topInset: topInset,
              topPadding: topPadding,
              bottomInset: bottomInset,
              bottomPadding: bottomPadding,
              horizontalPadding: horizontalPadding,
            ),
          ),
          Positioned(
            top: max(4, topInset + topPadding / 2 - 16),
            left: 8,
            right: 8,
            child: Align(
              alignment: Alignment.topLeft,
              child: _ReaderLayoutDebugBadge(
                color: const Color(0xFFB71C1C),
                text:
                    '顶部空白 ${topInset.round()} + ${topPadding.round()} = ${(topInset + topPadding).round()} px',
              ),
            ),
          ),
          if (bottomPadding > 0)
            Positioned(
              left: 8,
              bottom: max(4, bottomInset + 4),
              child: _ReaderLayoutDebugBadge(
                color: const Color(0xFF6A1B9A),
                text: '底部边距 ${bottomPadding.round()} px',
              ),
            ),
          Positioned(
            right: 8,
            bottom: bottomInset + _TextReaderViewState._pageFooterBottomInset,
            child: _ReaderLayoutDebugBadge(
              color: const Color(0xFF1565C0),
              text:
                  '页脚叠加层 bottom ${_TextReaderViewState._pageFooterBottomInset.round()} px',
            ),
          ),
          if (contentBottom > contentTop)
            Positioned(
              top: contentTop + 4,
              right: 8,
              child: _ReaderLayoutDebugBadge(
                color: const Color(0xFF1B5E20),
                text: '正文区 ${(contentBottom - contentTop).round()} px',
              ),
            ),
        ],
      ),
    );
  }
}

final class _ReaderLayoutDebugBadge extends StatelessWidget {
  const _ReaderLayoutDebugBadge({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: .9),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            height: 1.15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

final class _ReaderLayoutDebugPainter extends CustomPainter {
  const _ReaderLayoutDebugPainter({
    required this.topInset,
    required this.topPadding,
    required this.bottomInset,
    required this.bottomPadding,
    required this.horizontalPadding,
  });

  final double topInset;
  final double topPadding;
  final double bottomInset;
  final double bottomPadding;
  final double horizontalPadding;

  @override
  void paint(Canvas canvas, Size size) {
    final double contentTop = topInset + topPadding;
    final double contentBottom = size.height - bottomInset - bottomPadding;
    final Paint fill = Paint()..style = PaintingStyle.fill;
    final Paint outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    void fillRect(Rect rect, Color color) {
      fill.color = color;
      canvas.drawRect(rect, fill);
      outline.color = color.withValues(alpha: .85);
      canvas.drawRect(rect, outline);
    }

    if (topInset > 0) {
      fillRect(
        Rect.fromLTWH(0, 0, size.width, topInset),
        const Color(0x5539B9FF),
      );
    }
    if (topPadding > 0) {
      fillRect(
        Rect.fromLTWH(0, topInset, size.width, topPadding),
        const Color(0x55F44336),
      );
    }
    if (contentBottom > contentTop) {
      fillRect(
        Rect.fromLTRB(0, contentTop, size.width, contentBottom),
        const Color(0x221CAF50),
      );
      if (horizontalPadding > 0) {
        fillRect(
          Rect.fromLTRB(0, contentTop, horizontalPadding, contentBottom),
          const Color(0x55FFC107),
        );
        fillRect(
          Rect.fromLTRB(
            size.width - horizontalPadding,
            contentTop,
            size.width,
            contentBottom,
          ),
          const Color(0x55FFC107),
        );
      }
    }
    if (bottomPadding > 0) {
      fillRect(
        Rect.fromLTRB(
          0,
          size.height - bottomInset - bottomPadding,
          size.width,
          size.height - bottomInset,
        ),
        const Color(0x559C27B0),
      );
    }
    final double footerBottom =
        size.height - bottomInset - _TextReaderViewState._pageFooterBottomInset;
    final double footerTop = max(
      0,
      footerBottom - _readerPageFooterDebugHeight,
    );
    if (footerBottom > footerTop) {
      fillRect(
        Rect.fromLTRB(0, footerTop, size.width, footerBottom),
        const Color(0x55429BFF),
      );
    }
    if (bottomInset > 0) {
      fillRect(
        Rect.fromLTRB(0, size.height - bottomInset, size.width, size.height),
        const Color(0x5539B9FF),
      );
    }
  }

  @override
  bool shouldRepaint(_ReaderLayoutDebugPainter oldDelegate) =>
      topInset != oldDelegate.topInset ||
      topPadding != oldDelegate.topPadding ||
      bottomInset != oldDelegate.bottomInset ||
      bottomPadding != oldDelegate.bottomPadding ||
      horizontalPadding != oldDelegate.horizontalPadding;
}
