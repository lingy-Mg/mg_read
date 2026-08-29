part of 'text_reader_view.dart';

/// 阅读器局部加载、空态、边界遮罩和滚动行为组件。
///
/// 职责：
/// - 提供阅读器页面使用的无业务状态组件。
/// - 保持边界 spinner 与反向章节定位提示的一致几何。
///
/// 注意：
/// - 组件只接收不可变显示数据，不执行 IO 或修改会话状态。
///
/// TODO:
/// - 无。

class _CenteredStatus extends StatelessWidget {
  const _CenteredStatus({required this.color, required this.child});
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => DefaultTextStyle(
    style: TextStyle(color: color, fontSize: 15),
    child: Center(child: child),
  );
}

class _ReaderLoadingIndicator extends StatelessWidget {
  const _ReaderLoadingIndicator({
    required this.message,
    required this.indicatorColor,
    required this.textColor,
  });

  final String message;
  final Color indicatorColor;
  final Color textColor;

  @override
  Widget build(BuildContext context) => Semantics(
    label: message,
    liveRegion: true,
    excludeSemantics: true,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox.square(
          dimension: 30,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: indicatorColor,
          ),
        ),
        const SizedBox(height: 12),
        Text(message, style: TextStyle(color: textColor)),
      ],
    ),
  );
}

class _ChapterLoadingMask extends StatelessWidget {
  const _ChapterLoadingMask({required this.palette});

  final ReaderPalette palette;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: AbsorbPointer(
      child: ColoredBox(
        key: const ValueKey<String>('reader-chapter-loading-mask'),
        color: palette.background.withValues(alpha: 0.86),
        child: Center(
          child: _ReaderLoadingIndicator(
            message: ReaderStrings.loadingChapter,
            indicatorColor: palette.accent,
            textColor: palette.secondaryText,
          ),
        ),
      ),
    ),
  );
}

class _ReaderEmptyState extends StatelessWidget {
  const _ReaderEmptyState({
    required this.icon,
    required this.message,
    required this.color,
  });
  final IconData icon;
  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 32, color: color),
        const SizedBox(height: 10),
        Text(message, style: TextStyle(color: color, fontSize: 14)),
      ],
    ),
  );
}

/// Blocks another turn while a reverse chapter transition finishes measuring its tail page.
class _PreviousChapterTailMask extends StatelessWidget {
  const _PreviousChapterTailMask({required this.palette});
  final ReaderPalette palette;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: AbsorbPointer(
      child: ColoredBox(
        color: palette.background.withValues(alpha: 0.78),
        child: Center(
          child: _ReaderLoadingIndicator(
            message: '正在定位上一章末页',
            indicatorColor: palette.accent,
            textColor: palette.secondaryText,
          ),
        ),
      ),
    ),
  );
}

class _ReaderNotice extends StatelessWidget {
  const _ReaderNotice({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: SafeArea(
      child: Align(
        alignment: const Alignment(0, 0.72),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xE62A2926),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(
              message,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ),
      ),
    ),
  );
}

class _ReaderScrollBehavior extends MaterialScrollBehavior {
  const _ReaderScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.trackpad,
  };
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
