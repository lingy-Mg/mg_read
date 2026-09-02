part of 'text_reader_view.dart';

/// 为覆盖和仿真翻页组合移动页片；滑动和无动画翻页复用固定背景。
extension _TextReaderPageEffectWidgets on _TextReaderViewState {
  Widget _buildPageEffect(int rawIndex, Widget child) {
    // PageView.builder already inserts a repaint boundary around each child.
    // Cover/curl additionally need an inner boundary: their AnimatedBuilder
    // changes the outer transform/shading while this background + text sheet
    // remains static. Slide/none avoid the redundant boundary entirely.
    if (!_movingPageOwnsBackground) return child;
    final Widget pageSurface = RepaintBoundary(
      key: ValueKey<String>('reader-animated-page-boundary-$rawIndex'),
      child: ReaderBackgroundSurface(
        key: ValueKey<String>('reader-page-background-$rawIndex'),
        preset: _preferences.background,
        palette: _palette,
        child: child,
      ),
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return AnimatedBuilder(
          animation: _pageController,
          child: pageSurface,
          builder: (BuildContext context, Widget? child) {
            final double page = _pageController.hasClients
                ? (_pageController.page ??
                      _pageController.initialPage.toDouble())
                : _pageController.initialPage.toDouble();
            final double distance = (rawIndex - page)
                .abs()
                .clamp(0, 1)
                .toDouble();
            final bool entering = _pageTurnForward
                ? rawIndex > page
                : rawIndex < page;
            return Transform.translate(
              offset: Offset((page - rawIndex) * constraints.maxWidth, 0),
              child: ReaderPageEffect(
                animation: _preferences.pageAnimation,
                progress: entering ? 1 - distance : distance,
                entering: entering,
                forward: _pageTurnForward,
                reduceMotion: MediaQuery.disableAnimationsOf(context),
                child: child!,
              ),
            );
          },
        );
      },
    );
  }
}
