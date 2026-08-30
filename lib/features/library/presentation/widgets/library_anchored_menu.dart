/// 书架锚点菜单。
///
/// 职责：
/// - 在触发控件附近展示可逆的菜单开合过渡。
/// - 统一处理点外关闭、返回、Esc 与 reduce motion。
///
/// 注意：
/// - 菜单仅承载已提供的本地回调，不拥有书架业务状态。
/// - Overlay 与焦点节点必须随组件销毁释放，避免快速开合残留。
///
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mg_read/app/app_theme.dart';

/// 一项由宿主拥有的锚点菜单动作。
@immutable
final class LibraryAnchoredMenuAction {
  const LibraryAnchoredMenuAction({required this.label, required this.onSelected}) : assert(label != '');

  final String label;
  final VoidCallback onSelected;
}

/// 使用局部 Overlay 呈现的书架菜单。
class LibraryAnchoredMenu extends StatefulWidget {
  const LibraryAnchoredMenu({required this.tooltip, required this.actions, required this.triggerBuilder, this.menuKey, super.key});

  final String tooltip;
  final List<LibraryAnchoredMenuAction> actions;
  final Widget Function(BuildContext context, VoidCallback onPressed) triggerBuilder;
  final Key? menuKey;

  @override
  State<LibraryAnchoredMenu> createState() => _LibraryAnchoredMenuState();
}

class _LibraryAnchoredMenuState extends State<LibraryAnchoredMenu> with SingleTickerProviderStateMixin {
  final LayerLink _layerLink = LayerLink();
  final OverlayPortalController _portalController = OverlayPortalController();
  final FocusScopeNode _focusScopeNode = FocusScopeNode();
  late final AnimationController _controller;
  late final CurvedAnimation _progress;
  bool _isOpen = false;
  bool _isMountedInOverlay = false;

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
  void dispose() {
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
      child: CompositedTransformTarget(
        link: _layerLink,
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
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _dismiss, child: const SizedBox.expand()),
        ),
        CompositedTransformFollower(
          link: _layerLink,
          targetAnchor: Alignment.bottomCenter,
          followerAnchor: Alignment.topCenter,
          offset: const Offset(0, AppSpacing.compact),
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
              child: Semantics(
                container: true,
                label: widget.tooltip,
                child: Material(
                  key: widget.menuKey,
                  color: theme.colorScheme.surface,
                  elevation: 4,
                  shadowColor: Colors.black26,
                  borderRadius: AppRadii.surface,
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 160),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (final action in widget.actions)
                          TextButton(
                            onPressed: () {
                              _dismiss();
                              action.onSelected();
                            },
                            style: TextButton.styleFrom(
                              alignment: Alignment.centerLeft,
                              minimumSize: const Size(AppSpacing.minimumTouchTarget, AppSpacing.minimumTouchTarget),
                              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.comfortable),
                              foregroundColor: tokens.mutedText,
                            ),
                            child: Text(action.label),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
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
    setState(() {
      _isOpen = true;
    });
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
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 0;
      _hideIfStillClosed();
      return;
    }
    _controller.reverse().whenComplete(_hideIfStillClosed);
  }

  void _hideIfStillClosed() {
    if (!mounted || _isOpen || _controller.value != 0) return;
    _isMountedInOverlay = false;
    _portalController.hide();
  }
}
