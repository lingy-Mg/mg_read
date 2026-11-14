/// 表单文本输入连接共享静态输入控件；表单仍拥有校验、保存、重置和真实文本值。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'motion_text_field.dart';

class MotionTextFormField extends FormField<String> {
  MotionTextFormField({
    super.key,
    this.controller,
    String? initialValue,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.keyboardType,
    this.textInputAction,
    this.autocorrect = true,
    bool? enabled,
    this.maxLength,
    this.maxLines = 1,
    this.minLines,
    this.inputFormatters,
    this.onChanged,
    this.onFieldSubmitted,
    super.validator,
    super.onSaved,
    super.autovalidateMode,
  }) : super(
         initialValue: controller?.text ?? initialValue ?? '',
         enabled: enabled ?? true,
         builder: (field) {
           final state = field as _MotionTextFormFieldState;
           final widget = state.widget as MotionTextFormField;
           return MotionTextField(
             controller: state.controller,
             focusNode: widget.focusNode,
             decoration: widget.decoration.copyWith(errorText: field.errorText),
             keyboardType: widget.keyboardType,
             textInputAction: widget.textInputAction,
             autocorrect: widget.autocorrect,
             enabled: widget.enabled,
             maxLength: widget.maxLength,
             maxLines: widget.maxLines,
             minLines: widget.minLines,
             inputFormatters: widget.inputFormatters,
             onSubmitted: widget.onFieldSubmitted,
             onChanged: (value) {
               field.didChange(value);
               widget.onChanged?.call(value);
             },
           );
         },
       );
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration decoration;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool autocorrect;
  final int? maxLength;
  final int? maxLines;
  final int? minLines;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onFieldSubmitted;
  @override
  FormFieldState<String> createState() => _MotionTextFormFieldState();
}

class _MotionTextFormFieldState extends FormFieldState<String> {
  TextEditingController? _owned;
  MotionTextFormField get field => widget as MotionTextFormField;
  TextEditingController get controller =>
      field.controller ??
      (_owned ??= TextEditingController(text: widget.initialValue));
  @override
  void initState() {
    super.initState();
    controller.addListener(_sync);
  }

  void _sync() {
    if (controller.text != value) didChange(controller.text);
  }

  @override
  void didUpdateWidget(FormField<String> oldWidget) {
    final previous = (oldWidget as MotionTextFormField).controller ?? _owned;
    super.didUpdateWidget(oldWidget);
    if (previous != controller) {
      previous?.removeListener(_sync);
      if (field.controller == null && previous != null) {
        controller.value = previous.value;
      }
      controller.addListener(_sync);
      setValue(controller.text);
    }
  }

  @override
  void reset() {
    super.reset();
    controller.text = widget.initialValue ?? '';
    field.onChanged?.call(controller.text);
  }

  @override
  void dispose() {
    controller.removeListener(_sync);
    _owned?.dispose();
    super.dispose();
  }
}
