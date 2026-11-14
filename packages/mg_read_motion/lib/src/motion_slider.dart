/// 无动画滑杆直接提交手势/键盘位置并绘制真实值；不创建激活、光晕或位置过渡控制器。
/// onChangeStart/onChangeEnd 仍界定一次交互，拖动值与真实进度由调用方拥有。
library;

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'motion_policy.dart';
import 'motion_switch.dart';

class MotionSlider extends Slider {
  const MotionSlider({
    required super.value,
    required super.onChanged,
    super.min,
    super.max,
    super.divisions,
    super.onChangeStart,
    super.onChangeEnd,
    super.label,
    super.secondaryTrackValue,
    super.semanticFormatterCallback,
    super.padding,
    super.focusNode,
    super.autofocus,
    super.key,
  });
  @override
  State<Slider> createState() => _MotionSliderState();
  Widget _buildControl(BuildContext context) => MotionControlFocus(
    focusNode: focusNode,
    builder: (context, node) => motionDisabled(context)
        ? _StaticSlider(slider: this, focusNode: node)
        : Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            onChangeStart: onChangeStart,
            onChangeEnd: onChangeEnd,
            label: label,
            secondaryTrackValue: secondaryTrackValue,
            semanticFormatterCallback: semanticFormatterCallback,
            padding: padding,
            focusNode: node,
            autofocus: autofocus,
          ),
  );
}

class _MotionSliderState extends State<Slider> {
  @override
  Widget build(BuildContext context) =>
      (widget as MotionSlider)._buildControl(context);
}

class _StaticSlider extends StatefulWidget {
  const _StaticSlider({required this.slider, required this.focusNode});
  final MotionSlider slider;
  final FocusNode focusNode;
  @override
  State<_StaticSlider> createState() => _StaticSliderState();
}

class _StaticSliderState extends State<_StaticSlider> {
  bool _focused = false;
  double? _dragValue;
  bool _dragging = false;
  MotionSlider get slider => widget.slider;
  bool get enabled => slider.onChanged != null && slider.max > slider.min;
  double _quantize(double value) {
    final fraction = ((value - slider.min) / (slider.max - slider.min)).clamp(
      0.0,
      1.0,
    );
    return slider.min +
        (slider.divisions == null
                ? fraction
                : (fraction * slider.divisions!).round() / slider.divisions!) *
            (slider.max - slider.min);
  }

  void _changeBy(int direction) {
    if (!enabled) return;
    final next = _quantize(
      slider.value +
          direction * (slider.max - slider.min) / (slider.divisions ?? 20),
    );
    slider.onChangeStart?.call(slider.value);
    slider.onChanged!(next);
    slider.onChangeEnd?.call(next);
  }

  String _describe(double value) =>
      slider.semanticFormatterCallback?.call(value) ??
      '${((value - slider.min) / (slider.max - slider.min) * 100).round()}%';
  @override
  Widget build(BuildContext context) {
    final theme = SliderTheme.of(context);
    final overlayHeight =
        theme.overlayShape
            ?.getPreferredSize(enabled, slider.divisions != null)
            .height ??
        48;
    final thumbSize =
        theme.thumbShape?.getPreferredSize(enabled, slider.divisions != null) ??
        const Size.square(20);
    final controlHeight = math.max(
      32.0,
      math.max(overlayHeight, thumbSize.height),
    );
    final colors = Theme.of(context).colorScheme;
    final fraction = slider.max == slider.min
        ? 0.0
        : ((slider.value - slider.min) / (slider.max - slider.min)).clamp(
            0.0,
            1.0,
          );
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Semantics(
      slider: true,
      enabled: enabled,
      label: slider.label,
      value: slider.max == slider.min ? '0%' : _describe(slider.value),
      increasedValue: enabled
          ? _describe(
              _quantize(
                slider.value +
                    (slider.max - slider.min) / (slider.divisions ?? 20),
              ),
            )
          : null,
      decreasedValue: enabled
          ? _describe(
              _quantize(
                slider.value -
                    (slider.max - slider.min) / (slider.divisions ?? 20),
              ),
            )
          : null,
      onIncrease: enabled ? () => _changeBy(1) : null,
      onDecrease: enabled ? () => _changeBy(-1) : null,
      child: FocusableActionDetector(
        enabled: enabled,
        focusNode: widget.focusNode,
        autofocus: slider.autofocus,
        onShowFocusHighlight: (value) {
          if (_focused != value) setState(() => _focused = value);
        },
        shortcuts: {
          const SingleActivator(LogicalKeyboardKey.arrowRight): _SliderStep(
            rtl ? -1 : 1,
          ),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): _SliderStep(
            rtl ? 1 : -1,
          ),
          const SingleActivator(LogicalKeyboardKey.arrowUp): const _SliderStep(
            1,
          ),
          const SingleActivator(LogicalKeyboardKey.arrowDown):
              const _SliderStep(-1),
        },
        actions: {
          _SliderStep: CallbackAction<_SliderStep>(
            onInvoke: (intent) {
              _changeBy(intent.direction);
              return null;
            },
          ),
        },
        child: Padding(
          padding: slider.padding ?? const EdgeInsets.symmetric(horizontal: 24),
          child: LayoutBuilder(
            builder: (context, constraints) {
              double position(double x) => _quantize(
                slider.min +
                    (rtl
                            ? 1 - x / constraints.maxWidth
                            : x / constraints.maxWidth) *
                        (slider.max - slider.min),
              );
              void update(double x) {
                _dragValue = position(x);
                slider.onChanged!(_dragValue!);
              }

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTapUp: enabled
                    ? (details) {
                        slider.onChangeStart?.call(slider.value);
                        update(details.localPosition.dx);
                        slider.onChangeEnd?.call(_dragValue!);
                      }
                    : null,
                onHorizontalDragStart: enabled
                    ? (details) {
                        _dragging = true;
                        slider.onChangeStart?.call(slider.value);
                        update(details.localPosition.dx);
                      }
                    : null,
                onHorizontalDragUpdate: enabled
                    ? (details) => update(details.localPosition.dx)
                    : null,
                onHorizontalDragEnd: enabled
                    ? (_) {
                        _dragging = false;
                        slider.onChangeEnd?.call(_dragValue ?? slider.value);
                      }
                    : null,
                onHorizontalDragCancel: enabled
                    ? () {
                        if (_dragging) {
                          _dragging = false;
                          slider.onChangeEnd?.call(_dragValue ?? slider.value);
                        }
                      }
                    : null,
                child: SizedBox(
                  height: controlHeight,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        height: theme.trackHeight ?? 4,
                        decoration: BoxDecoration(
                          color: enabled
                              ? theme.inactiveTrackColor ??
                                    colors.surfaceContainerHighest
                              : colors.onSurface.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: FractionallySizedBox(
                          widthFactor:
                              slider.secondaryTrackValue == null ||
                                  slider.max == slider.min
                              ? 0
                              : ((slider.secondaryTrackValue! - slider.min) /
                                        (slider.max - slider.min))
                                    .clamp(0, 1),
                          child: Container(
                            height: theme.trackHeight ?? 4,
                            color:
                                theme.secondaryActiveTrackColor ??
                                colors.primary.withValues(alpha: .3),
                          ),
                        ),
                      ),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: FractionallySizedBox(
                          widthFactor: fraction,
                          child: Container(
                            height: theme.trackHeight ?? 4,
                            color: theme.activeTrackColor ?? colors.primary,
                          ),
                        ),
                      ),
                      Align(
                        alignment: AlignmentDirectional(-1 + 2 * fraction, 0),
                        child: Container(
                          width: thumbSize.width,
                          height: thumbSize.height,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: enabled
                                ? theme.thumbColor ?? colors.primary
                                : colors.outline,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SliderStep extends Intent {
  const _SliderStep(this.direction);
  final int direction;
}
