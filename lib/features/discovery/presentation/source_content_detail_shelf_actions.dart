part of 'source_content_detail_sheet.dart';

/// Shelf state actions and their confirmation/loading behavior.
class _ShelfActionBar extends StatefulWidget {
  const _ShelfActionBar({
    required this.title,
    required this.shelfState,
    required this.onAction,
    required this.onStartReading,
    required this.canStartReading,
    this.isCoverBlurred = false,
  });

  final String? title;
  final SourceDetailShelfState shelfState;
  final SourceShelfActionRequested onAction;
  final SourceStartReadingRequested onStartReading;
  final bool canStartReading;
  final bool isCoverBlurred;

  @override
  State<_ShelfActionBar> createState() => _ShelfActionBarState();
}

class _ShelfActionBarState extends State<_ShelfActionBar> {
  SourceShelfAction? _runningAction;
  late bool _isCoverBlurred;

  @override
  void initState() {
    super.initState();
    _isCoverBlurred = widget.isCoverBlurred;
  }

  @override
  void didUpdateWidget(covariant _ShelfActionBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_runningAction == null && oldWidget.isCoverBlurred != widget.isCoverBlurred) {
      _isCoverBlurred = widget.isCoverBlurred;
    }
  }

  bool get _isRunning => _runningAction != null;
  bool get _isRefreshing => _runningAction == SourceShelfAction.refresh;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final bool isPrivate = widget.shelfState == SourceDetailShelfState.private;
    final shape = RoundedRectangleBorder(borderRadius: AppRadii.control);
    ButtonStyle style(Color foreground, Color border) => OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(50),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.unit),
      foregroundColor: _isRunning ? tokens.mutedText : foreground,
      side: BorderSide(color: _isRunning ? tokens.divider : border),
      shape: shape,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        const int columnCount = 3;
        final actionWidth = (constraints.maxWidth - AppSpacing.compact * (columnCount - 1)) / columnCount;
        return Wrap(
          spacing: AppSpacing.compact,
          runSpacing: AppSpacing.compact,
          children: <Widget>[
            SizedBox(
              width: actionWidth,
              child: OutlinedButton.icon(
                key: const Key('source-detail-refresh-action'),
                onPressed: _isRunning ? null : () => _run(SourceShelfAction.refresh),
                icon: _isRefreshing
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh_rounded),
                label: Text(_isRefreshing ? '刷新中' : '刷新'),
                style: style(tokens.accent, tokens.accent),
              ),
            ),
            SizedBox(
              width: actionWidth,
              child: OutlinedButton.icon(
                key: const Key('source-detail-privacy-action'),
                onPressed: _isRunning ? null : () => _run(isPrivate ? SourceShelfAction.cancelPrivate : SourceShelfAction.setPrivate),
                icon: Icon(isPrivate ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                label: Text(isPrivate ? '取消隐私' : '隐私'),
                style: style(tokens.mutedText, tokens.divider),
              ),
            ),
            SizedBox(
              width: actionWidth,
              child: OutlinedButton.icon(
                key: const Key('source-detail-cover-blur-action'),
                onPressed: _isRunning ? null : () => _run(SourceShelfAction.toggleCoverBlur),
                icon: Icon(_isCoverBlurred ? Icons.blur_off_rounded : Icons.blur_on_rounded),
                label: Text(_isCoverBlurred ? '取消模糊' : '模糊封面'),
                style: style(tokens.mutedText, tokens.divider),
              ),
            ),
            SizedBox(
              width: actionWidth,
              child: OutlinedButton.icon(
                key: const Key('source-detail-delete-action'),
                onPressed: _isRunning ? null : () => _confirmDelete(context),
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('删除'),
                style: style(Theme.of(context).colorScheme.error, Theme.of(context).colorScheme.error.withValues(alpha: .58)),
              ),
            ),
            SizedBox(
              width: actionWidth,
              child: OutlinedButton.icon(
                key: const Key('source-detail-start-reading'),
                onPressed: _isRunning || !widget.canStartReading ? null : _startReading,
                icon: const Icon(Icons.menu_book_rounded),
                label: const Text('开始阅读'),
                style: style(tokens.accent, tokens.accent),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _startReading() async {
    if (_isRunning || !widget.canStartReading) return;
    Navigator.of(context).pop();
    await widget.onStartReading();
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showBookshelfRemovalConfirmation(context, title: widget.title);
    if (confirmed && mounted) await _run(SourceShelfAction.delete);
  }

  Future<void> _run(SourceShelfAction action) async {
    if (_isRunning) return;
    setState(() => _runningAction = action);
    try {
      await widget.onAction(action);
      if (!mounted) return;
      if (action == SourceShelfAction.toggleCoverBlur) {
        setState(() => _isCoverBlurred = !_isCoverBlurred);
      } else if (action != SourceShelfAction.refresh) {
        Navigator.of(context).pop();
      }
    } on Object catch (error) {
      if (!mounted) return;
      if (action == SourceShelfAction.refresh) {
        await showAppOperationErrorDialog(context, operation: '刷新书籍', error: error, guidance: '书架已保留刷新前的数据。请稍后重试。');
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('操作未能完成，请稍后重试。')));
    } finally {
      if (mounted) setState(() => _runningAction = null);
    }
  }
}
