/// 书架条目的横向操作面板。
///
/// 职责：
/// - 在书籍行向左拖动后展示宿主提供的操作按钮。
/// - 保留子项点击、长按和语义树的原有归属。
///
/// 注意：
/// - 不拥有业务状态，按钮动作由书架列表转发给页面。
/// - 拖动动画和控制器必须在组件销毁时释放。
///
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list_action.dart';

/// Wraps one book row with a revealable trailing action panel.
class LibraryBookSwipeActions extends StatefulWidget {
  const LibraryBookSwipeActions({required this.book, required this.child, required this.actions, required this.onAction, super.key});

  final LibraryBookListItemViewData book;
  final Widget child;
  final List<LibraryBookListAction> actions;
  final ValueChanged<LibraryBookListAction> onAction;

  @override
  State<LibraryBookSwipeActions> createState() => _LibraryBookSwipeActionsState();
}

class _LibraryBookSwipeActionsState extends State<LibraryBookSwipeActions> with SingleTickerProviderStateMixin {
  static const double _buttonWidth = 84;
  static const Duration _animationDuration = Duration(milliseconds: 220);

  late final AnimationController _animationController;
  Animation<double>? _animation;
  double _offset = 0;

  double get _maxOffset => widget.actions.length * _buttonWidth;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(vsync: this, duration: _animationDuration)
      ..addListener(() {
        if (!mounted || _animation == null) return;
        setState(() => _offset = _animation!.value);
      });
  }

  @override
  void didUpdateWidget(covariant LibraryBookSwipeActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.actions.length != widget.actions.length && _offset > _maxOffset) {
      _offset = _maxOffset;
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return ClipRect(
      child: Stack(
        alignment: Alignment.centerRight,
        children: <Widget>[
          if (_offset > 0)
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: _offset,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.centerRight,
                      minWidth: _maxOffset,
                      maxWidth: _maxOffset,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: <Widget>[
                          for (final action in widget.actions)
                            SizedBox(
                              width: _buttonWidth,
                              child: Material(
                                color: _actionColor(theme, tokens, action),
                                child: InkWell(
                                  key: ValueKey<String>('library-book-swipe-action-${action.id}'),
                                  onTap: () {
                                    _animateTo(0);
                                    widget.onAction(action);
                                  },
                                  child: Center(
                                    child: Text(
                                      action.labelFor(widget.book),
                                      style: theme.textTheme.bodyMedium?.copyWith(color: _actionForeground(theme, tokens, action)),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Transform.translate(
            offset: Offset(-_offset, 0),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (DragUpdateDetails details) {
                _animationController.stop();
                setState(() => _offset = math.min(_maxOffset, math.max(0, _offset - details.delta.dx)));
              },
              onHorizontalDragEnd: (_) => _animateTo(_offset >= _maxOffset / 2 ? _maxOffset : 0),
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }

  void _animateTo(double target) {
    final double begin = _offset;
    if ((begin - target).abs() < 0.1) {
      setState(() => _offset = target);
      return;
    }
    _animation = Tween<double>(
      begin: begin,
      end: target,
    ).animate(CurvedAnimation(parent: _animationController, curve: Curves.easeOutCubic));
    _animationController
      ..duration = MediaQuery.disableAnimationsOf(context) ? Duration.zero : _animationDuration
      ..forward(from: 0);
  }

  Color _actionColor(ThemeData theme, AppThemeTokens tokens, LibraryBookListAction action) {
    return action.id == 'delete' ? theme.colorScheme.error : tokens.accent;
  }

  Color _actionForeground(ThemeData theme, AppThemeTokens tokens, LibraryBookListAction action) {
    return action.id == 'delete' ? theme.colorScheme.onError : theme.colorScheme.onPrimary;
  }
}
