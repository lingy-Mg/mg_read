/// 书架锚点菜单。
///
/// 职责：
/// - 在触发控件附近展示可逆的菜单开合过渡。
/// - 统一处理点外关闭、返回、Esc 与 reduce motion。
/// - 限制菜单宽度，在安全区内贴右对齐；底部空间不足时向上展开。
///
/// 注意：
/// - 菜单仅承载已提供的本地回调，不拥有书架业务状态。
/// - Overlay 与焦点节点必须随组件销毁释放，避免快速开合残留。
/// - 宿主滚动时关闭菜单，避免操作指向已经移位的书籍。
///
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mg_read/app/app_theme.dart';

/// 一项由宿主拥有的锚点菜单动作。
@immutable
final class LibraryAnchoredMenuAction {
  const LibraryAnchoredMenuAction({
    required this.label,
    required this.onSelected,
    this.icon,
    this.isDestructive = false,
    this.startsSection = false,
    this.key,
  }) : assert(label != '');

  final String label;
  final VoidCallback onSelected;
  final IconData? icon;
  final bool isDestructive;
  final bool startsSection;
  final Key? key;
}

/// 使用局部 Overlay 呈现的书架菜单。
class LibraryAnchoredMenu extends StatefulWidget {
  const LibraryAnchoredMenu({
    required this.tooltip,
    required this.actions,
    required this.triggerBuilder,
    this.menuKey,
    this.onOpenChanged,
    super.key,
  });

  final String tooltip;
  final List<LibraryAnchoredMenuAction> actions;
  final Widget Function(BuildContext context, VoidCallback onPressed) triggerBuilder;
  final Key? menuKey;
  final ValueChanged<bool>? onOpenChanged;

  @override
  State<LibraryAnchoredMenu> createState() => _LibraryAnchoredMenuState();
}

class _LibraryAnchoredMenuState extends State<LibraryAnchoredMenu> with SingleTickerProviderStateMixin {
  final GlobalKey _anchorKey = GlobalKey();
  final OverlayPortalController _portalController = OverlayPortalController();
  final FocusScopeNode _focusScopeNode = FocusScopeNode();
  late final AnimationController _controller;
  late final CurvedAnimation _progress;
  bool _isOpen = false;
  bool _isMountedInOverlay = false;
  ScrollPosition? _scrollPosition;
  FocusNode? _previousFocus;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: AppMotion.destinationTransition,
      reverseDuration: AppMotion.destinationTransition,
      vsync: this,
    );
    _progress = CurvedAnimation(parent: _controller, curve: AppMotion.navigationCurve, reverseCurve: AppMotion.navigationReverseCurve);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.disablesAnimations(context) && _controller.isAnimating) {
      _controller.value = _isOpen ? 1 : 0;
      if (!_isOpen) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _hideIfStillClosed();
        });
      }
    }
    final ScrollPosition? position = Scrollable.maybeOf(context)?.position;
    if (position == _scrollPosition) return;
    _scrollPosition?.removeListener(_dismiss);
    _scrollPosition = position;
    _scrollPosition?.addListener(_dismiss);
  }

  @override
  void dispose() {
    _scrollPosition?.removeListener(_dismiss);
    _progress.dispose();
    _controller.dispose();
    _focusScopeNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isOpen,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) _dismiss();
      },
      child: KeyedSubtree(
        key: _anchorKey,
        child: OverlayPortal(
          controller: _portalController,
          overlayChildBuilder: _buildOverlay,
          child: widget.triggerBuilder(context, _toggle),
        ),
      ),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    // Layout is in overlay coordinates, even when the trigger is below a SafeArea.
    final MediaQueryData overlayMedia = MediaQuery.of(Overlay.of(context).context);
    final TextScaler textScaler = MediaQuery.textScalerOf(context);
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _dismiss, child: const SizedBox.expand()),
        ),
        Positioned.fill(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final RenderBox anchor = _anchorKey.currentContext!.findRenderObject()! as RenderBox;
              final RenderBox overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
              final Rect anchorRect = overlay.globalToLocal(anchor.localToGlobal(Offset.zero)) & anchor.size;
              return CustomSingleChildLayout(
                delegate: _LibraryMenuLayout(
                  anchor: anchorRect,
                  padding: overlayMedia.padding + overlayMedia.viewInsets + const EdgeInsets.all(AppSpacing.regular),
                  width: (224 * textScaler.scale(14) / 14).clamp(224, 320),
                ),
                child: FocusScope(
                  node: _focusScopeNode,
                  onKeyEvent: (FocusNode node, KeyEvent event) {
                    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
                      _dismiss();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: AnimatedBuilder(
                    animation: _progress,
                    builder: (BuildContext context, Widget? child) {
                      final double progress = _progress.value;
                      return Opacity(
                        opacity: progress,
                        child: Transform.translate(
                          offset: Offset(0, (1 - progress) * AppSpacing.compact),
                          child: Transform.scale(scale: 0.96 + progress * 0.04, alignment: Alignment.topRight, child: child),
                        ),
                      );
                    },
                    child: IgnorePointer(
                      ignoring: !_isOpen,
                      child: Semantics(
                        container: true,
                        explicitChildNodes: true,
                        scopesRoute: true,
                        namesRoute: true,
                        label: widget.tooltip,
                        child: Material(
                          key: widget.menuKey,
                          color: tokens.surface,
                          surfaceTintColor: Colors.transparent,
                          elevation: 8,
                          shadowColor: tokens.shadow.withValues(alpha: 0.16),
                          shape: RoundedRectangleBorder(
                            borderRadius: AppRadii.card,
                            side: BorderSide(color: tokens.divider),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: SingleChildScrollView(
                            primary: false,
                            padding: const EdgeInsets.all(AppSpacing.compact),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                for (final (index, action) in widget.actions.indexed) ...<Widget>[
                                  if (index > 0 && action.startsSection)
                                    Divider(
                                      height: AppSpacing.regular,
                                      indent: AppSpacing.regular,
                                      endIndent: AppSpacing.regular,
                                      color: tokens.divider,
                                    ),
                                  TextButton(
                                    key: action.key,
                                    autofocus: index == 0,
                                    onPressed: () {
                                      _dismiss();
                                      action.onSelected();
                                    },
                                    style: TextButton.styleFrom(
                                      alignment: Alignment.centerLeft,
                                      minimumSize: const Size(AppSpacing.minimumTouchTarget, AppSpacing.minimumTouchTarget),
                                      padding: const EdgeInsets.all(AppSpacing.regular),
                                      shape: const RoundedRectangleBorder(borderRadius: AppRadii.discoveryTile),
                                      foregroundColor: action.isDestructive ? theme.colorScheme.error : theme.colorScheme.onSurface,
                                      textStyle: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                                    ),
                                    child: Row(
                                      children: <Widget>[
                                        if (action.icon != null) ...<Widget>[
                                          Icon(action.icon, size: 20),
                                          const SizedBox(width: AppSpacing.regular),
                                        ],
                                        Expanded(child: Text(action.label)),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _toggle() {
    if (_isOpen) {
      _dismiss();
    } else {
      _show();
    }
  }

  void _show() {
    if (widget.actions.isEmpty) return;
    _previousFocus = FocusManager.instance.primaryFocus;
    setState(() {
      _isOpen = true;
    });
    widget.onOpenChanged?.call(true);
    if (!_isMountedInOverlay) {
      _isMountedInOverlay = true;
      _portalController.show();
    }
    _focusScopeNode.requestFocus();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  void _dismiss() {
    if (!_isMountedInOverlay || !_isOpen) return;
    setState(() {
      _isOpen = false;
    });
    widget.onOpenChanged?.call(false);
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 0;
      _hideIfStillClosed();
      return;
    }
    _controller.reverse().whenComplete(_hideIfStillClosed);
  }

  void _hideIfStillClosed() {
    if (!mounted || _isOpen || _controller.value != 0) return;
    if (_focusScopeNode.hasFocus && (_previousFocus?.canRequestFocus ?? false)) {
      _previousFocus!.requestFocus();
    }
    _isMountedInOverlay = false;
    _portalController.hide();
  }
}

/// Uses the measured menu height to flip above the trigger and clamp to the safe area.
class _LibraryMenuLayout extends SingleChildLayoutDelegate {
  const _LibraryMenuLayout({required this.anchor, required this.padding, required this.width});

  final Rect anchor;
  final EdgeInsets padding;
  final double width;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final double availableWidth = (constraints.maxWidth - padding.horizontal).clamp(0, double.infinity);
    return BoxConstraints(
      minWidth: width.clamp(0, availableWidth),
      maxWidth: width.clamp(0, availableWidth),
      maxHeight: (constraints.maxHeight - padding.vertical).clamp(0, double.infinity),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double maxLeft = (size.width - padding.right - childSize.width).clamp(padding.left, double.infinity);
    final double maxTop = (size.height - padding.bottom - childSize.height).clamp(padding.top, double.infinity);
    final double below = anchor.bottom + AppSpacing.compact;
    final double top = below <= maxTop ? below : anchor.top - AppSpacing.compact - childSize.height;
    return Offset((anchor.right - childSize.width).clamp(padding.left, maxLeft), top.clamp(padding.top, maxTop));
  }

  @override
  bool shouldRelayout(_LibraryMenuLayout oldDelegate) =>
      anchor != oldDelegate.anchor || padding != oldDelegate.padding || width != oldDelegate.width;
}
