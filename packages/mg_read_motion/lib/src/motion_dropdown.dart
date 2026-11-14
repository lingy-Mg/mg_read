/// 下拉选择的无动画分支以零时长菜单直接提交真实值；正常模式保留 Flutter 下拉样式。
/// 表单拥有校验/保存状态，组件不持有设置或业务会话。
library;

import 'package:flutter/material.dart';
import 'motion_policy.dart';

class MotionDropdownButton<T> extends StatelessWidget {
  const MotionDropdownButton({
    required this.items,
    required this.onChanged,
    this.value,
    this.isExpanded = false,
    this.hint,
    this.style,
    this.dropdownColor,
    super.key,
  });
  final List<DropdownMenuItem<T>>? items;
  final ValueChanged<T?>? onChanged;
  final T? value;
  final bool isExpanded;
  final Widget? hint;
  final TextStyle? style;
  final Color? dropdownColor;
  @override
  Widget build(BuildContext context) {
    if (!motionDisabled(context)) {
      return DropdownButton<T>(
        items: items,
        value: value,
        onChanged: onChanged,
        isExpanded: isExpanded,
        hint: hint,
        style: style,
        dropdownColor: dropdownColor,
      );
    }
    final selected = items?.where((item) => item.value == value).firstOrNull;
    return PopupMenuButton<T>(
      enabled: onChanged != null && items?.isNotEmpty == true,
      initialValue: value,
      onSelected: onChanged,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      color: dropdownColor,
      tooltip: '',
      itemBuilder: (_) => [
        for (final item in items ?? <DropdownMenuItem<T>>[])
          PopupMenuItem<T>(
            value: item.value,
            enabled: item.enabled,
            child: item.child,
          ),
      ],
      child: Semantics(
        button: true,
        enabled: onChanged != null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: DefaultTextStyle(
            style: style ?? Theme.of(context).textTheme.bodyLarge!,
            child: Row(
              mainAxisSize: isExpanded ? MainAxisSize.max : MainAxisSize.min,
              children: [
                if (isExpanded)
                  Expanded(
                    child: selected?.child ?? hint ?? const SizedBox.shrink(),
                  )
                else
                  selected?.child ?? hint ?? const SizedBox.shrink(),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MotionDropdownButtonFormField<T> extends StatefulWidget {
  const MotionDropdownButtonFormField({
    required this.items,
    required this.onChanged,
    this.initialValue,
    this.decoration = const InputDecoration(),
    this.isExpanded = false,
    this.hint,
    this.style,
    this.dropdownColor,
    this.validator,
    this.onSaved,
    this.autovalidateMode,
    super.key,
  });
  final List<DropdownMenuItem<T>>? items;
  final ValueChanged<T?>? onChanged;
  final T? initialValue;
  final InputDecoration decoration;
  final bool isExpanded;
  final Widget? hint;
  final TextStyle? style;
  final Color? dropdownColor;
  final FormFieldValidator<T>? validator;
  final FormFieldSetter<T>? onSaved;
  final AutovalidateMode? autovalidateMode;
  @override
  State<MotionDropdownButtonFormField<T>> createState() =>
      _MotionDropdownFieldState<T>();
}

class _MotionDropdownFieldState<T>
    extends State<MotionDropdownButtonFormField<T>> {
  var _field = GlobalKey<FormFieldState<T>>();
  @override
  void didUpdateWidget(MotionDropdownButtonFormField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue &&
        _field.currentState?.value != widget.initialValue) {
      _field = GlobalKey<FormFieldState<T>>();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!motionDisabled(context)) {
      return DropdownButtonFormField<T>(
        key: _field,
        items: widget.items,
        initialValue: widget.initialValue,
        onChanged: widget.onChanged,
        decoration: widget.decoration,
        isExpanded: widget.isExpanded,
        hint: widget.hint,
        style: widget.style,
        dropdownColor: widget.dropdownColor,
        validator: widget.validator,
        onSaved: widget.onSaved,
        autovalidateMode: widget.autovalidateMode,
      );
    }
    return FormField<T>(
      key: _field,
      initialValue: widget.initialValue,
      validator: widget.validator,
      onSaved: widget.onSaved,
      autovalidateMode: widget.autovalidateMode ?? AutovalidateMode.disabled,
      builder: (field) => InputDecorator(
        decoration: widget.decoration.copyWith(
          errorText: field.errorText,
          enabled: widget.onChanged != null,
          floatingLabelBehavior: FloatingLabelBehavior.always,
        ),
        child: MotionDropdownButton<T>(
          items: widget.items,
          value: field.value,
          hint: widget.hint,
          isExpanded: widget.isExpanded,
          style: widget.style,
          dropdownColor: widget.dropdownColor,
          onChanged: widget.onChanged == null
              ? null
              : (value) {
                  field.didChange(value);
                  widget.onChanged!(value);
                },
        ),
      ),
    );
  }
}
