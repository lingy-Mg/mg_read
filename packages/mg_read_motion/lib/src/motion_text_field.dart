/// 文本输入的静态分支：即时边框/标签与静态光标，不启动光标闪烁或输入装饰过渡。
/// 控制器、焦点和内部 EditableText 通过稳定 key 保留，策略变化不丢失文本、选择或输入连接。
library;

import 'package:flutter/material.dart';
import 'motion_policy.dart';

class MotionTextField extends TextField {
  const MotionTextField({
    super.key,
    super.controller,
    super.focusNode,
    super.decoration,
    super.style,
    super.keyboardType,
    super.textInputAction,
    super.autofocus,
    super.autocorrect,
    super.readOnly,
    super.enabled,
    super.maxLength,
    super.maxLines,
    super.minLines,
    super.inputFormatters,
    super.onChanged,
    super.onSubmitted,
    super.showCursor,
  });
  @override
  State<TextField> createState() => _MotionTextFieldState();
}

class _MotionTextFieldState extends State<TextField> {
  final _inputKey = GlobalKey();
  final _surfaceKey = GlobalKey();
  final _ownedFocus = FocusNode();
  final _scroll = _MotionTextScrollController();
  TextEditingController? _ownedController;
  TextEditingController get controller =>
      widget.controller ?? (_ownedController ??= TextEditingController());
  FocusNode get focus => widget.focusNode ?? _ownedFocus;
  @override
  void didUpdateWidget(TextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != null && widget.controller == null) {
      controller.value = oldWidget.controller!.value;
    }
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    _ownedFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _input({required bool disabled}) => TextField(
    key: _inputKey,
    controller: controller,
    focusNode: focus,
    decoration: disabled ? null : widget.decoration,
    style: widget.style,
    keyboardType: widget.keyboardType,
    textInputAction: widget.textInputAction,
    autofocus: widget.autofocus,
    autocorrect: widget.autocorrect,
    readOnly: widget.readOnly,
    enabled: widget.enabled,
    maxLength: widget.maxLength,
    maxLines: widget.maxLines,
    minLines: widget.minLines,
    inputFormatters: widget.inputFormatters,
    onChanged: widget.onChanged,
    onSubmitted: widget.onSubmitted,
    showCursor: disabled ? false : widget.showCursor,
    selectionControls: disabled
        ? desktopTextSelectionControls
        : widget.selectionControls,
    magnifierConfiguration: disabled
        ? TextMagnifierConfiguration.disabled
        : widget.magnifierConfiguration,
    scrollController: _scroll,
  );
  @override
  Widget build(BuildContext context) {
    _scroll.disabled = motionDisabled(context);
    if (!motionDisabled(context)) return _input(disabled: false);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([controller, focus]),
      builder: (context, _) {
        final decoration = (widget.decoration ?? const InputDecoration())
            .applyDefaults(InputDecorationTheme.of(context));
        final enabled = widget.enabled ?? decoration.enabled;
        final border = !enabled
            ? decoration.disabledBorder
            : decoration.errorText != null
            ? (focus.hasFocus
                  ? decoration.focusedErrorBorder
                  : decoration.errorBorder)
            : focus.hasFocus
            ? decoration.focusedBorder
            : decoration.enabledBorder;
        final labelStyle = decoration.labelStyle ?? theme.textTheme.bodySmall!;
        final input = DecoratedBox(
          decoration: ShapeDecoration(
            shape: border ?? decoration.border ?? const UnderlineInputBorder(),
            color: decoration.filled == true ? decoration.fillColor : null,
          ),
          child: Padding(
            padding:
                decoration.contentPadding ??
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                if (decoration.prefixIcon != null) ...[
                  decoration.prefixIcon!,
                  const SizedBox(width: 8),
                ],
                if (decoration.prefix != null) decoration.prefix!,
                if (decoration.prefixText != null)
                  Text(decoration.prefixText!, style: decoration.prefixStyle),
                Expanded(
                  child: Stack(
                    alignment: AlignmentDirectional.centerStart,
                    children: [
                      if (controller.text.isEmpty &&
                          decoration.hintText != null)
                        IgnorePointer(
                          child: Text(
                            decoration.hintText!,
                            style:
                                decoration.hintStyle ??
                                theme.textTheme.bodyLarge?.copyWith(
                                  color: theme.hintColor,
                                ),
                          ),
                        ),
                      _input(disabled: true),
                    ],
                  ),
                ),
                if (decoration.suffixText != null)
                  Text(decoration.suffixText!, style: decoration.suffixStyle),
                if (decoration.suffix != null) decoration.suffix!,
                if (decoration.suffixIcon != null) ...[
                  const SizedBox(width: 8),
                  decoration.suffixIcon!,
                ],
              ],
            ),
          ),
        );
        return CustomPaint(
          key: _surfaceKey,
          foregroundPainter: _StaticCaretPainter(
            inputKey: _inputKey,
            surfaceKey: _surfaceKey,
            controller: controller,
            focus: focus,
            color:
                theme.textSelectionTheme.cursorColor ??
                theme.colorScheme.primary,
            visible: enabled && (widget.showCursor ?? !widget.readOnly),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (decoration.label != null) decoration.label!,
              if (decoration.labelText != null) ...[
                Text(decoration.labelText!, style: labelStyle),
                const SizedBox(height: 4),
              ],
              input,
              if (decoration.errorText != null)
                Text(
                  decoration.errorText!,
                  style:
                      decoration.errorStyle ??
                      theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                )
              else if (decoration.helperText != null)
                Text(decoration.helperText!, style: decoration.helperStyle),
              if (decoration.counterText != null &&
                  decoration.counterText!.isNotEmpty)
                Text(decoration.counterText!, style: decoration.counterStyle)
              else if (decoration.counterText == null &&
                  widget.maxLength != null &&
                  widget.maxLength! > 0)
                Text(
                  '${controller.text.characters.length}/${widget.maxLength}',
                  style: decoration.counterStyle ?? theme.textTheme.bodySmall,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// EditableText 的光标跟随也会调用 animateTo，不能只关闭可见光标的闪烁。
class _MotionTextScrollController extends ScrollController {
  bool _disabled = false;
  bool get disabled => _disabled;
  set disabled(bool value) {
    if (_disabled == value) return;
    _disabled = value;
    if (value) {
      for (final position in positions.whereType<_MotionTextScrollPosition>()) {
        position.finishMotion();
      }
    }
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _MotionTextScrollPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    owner: this,
  );
}

class _MotionTextScrollPosition extends ScrollPositionWithSingleContext {
  _MotionTextScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.owner,
  });
  final _MotionTextScrollController owner;
  double? _target;
  void finishMotion() {
    if (_target != null && activity is DrivenScrollActivity) jumpTo(_target!);
  }

  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) {
    _target = to;
    if (owner.disabled) {
      jumpTo(to);
      return Future<void>.value();
    }
    return super.animateTo(to, duration: duration, curve: curve);
  }
}

class _StaticCaretPainter extends CustomPainter {
  _StaticCaretPainter({
    required this.inputKey,
    required this.surfaceKey,
    required this.controller,
    required this.focus,
    required this.color,
    required this.visible,
  }) : super(repaint: Listenable.merge([controller, focus]));
  final GlobalKey inputKey;
  final GlobalKey surfaceKey;
  final TextEditingController controller;
  final FocusNode focus;
  final Color color;
  final bool visible;
  @override
  void paint(Canvas canvas, Size size) {
    if (!visible ||
        !focus.hasFocus ||
        !controller.selection.isCollapsed ||
        !controller.selection.isValid) {
      return;
    }
    EditableTextState? editable;
    void visit(Element element) {
      if (element is StatefulElement && element.state is EditableTextState) {
        editable = element.state as EditableTextState;
      } else {
        element.visitChildElements(visit);
      }
    }

    inputKey.currentContext?.visitChildElements(visit);
    final render = editable?.renderEditable;
    final surface = surfaceKey.currentContext?.findRenderObject();
    if (render == null || surface is! RenderBox || !render.hasSize) return;
    final caret = render.getLocalRectForCaret(controller.selection.extent);
    final offset = render.localToGlobal(caret.topLeft, ancestor: surface);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(
      Rect.fromLTWH(offset.dx, offset.dy, 2, caret.height),
      Paint()..color = color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StaticCaretPainter oldDelegate) =>
      color != oldDelegate.color ||
      visible != oldDelegate.visible ||
      controller != oldDelegate.controller ||
      focus != oldDelegate.focus;
}
