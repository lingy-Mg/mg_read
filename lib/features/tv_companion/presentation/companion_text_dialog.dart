/// Phone IME editing with serialized full-text revisions. Composing text stays
/// local. Cancel restores the original TV draft; local TV edits fence this token.
library;

import 'package:mg_read/shared/presentation/motion/app_motion.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../application/companion_controller.dart';
import '../domain/companion_command.dart';
import '../domain/companion_models.dart';
import 'companion_messages.dart';

Future<void> showCompanionTextDialog(BuildContext context, CompanionController service) async {
  final interaction = await service.beginInteraction();
  final receipt = await service.interactionCommand(interaction, CompanionCommandType.beginTextInput);
  if (receipt.phase != CompanionCommandPhase.applied) throw CompanionFailure(receipt.code ?? 'text_context_changed');
  if (!context.mounted) {
    service
        .interactionCommand(
          interaction,
          CompanionCommandType.cancelTextInput,
          arguments: {'sessionId': receipt.details['sessionId'], 'generation': receipt.details['generation']},
        )
        .ignore();
    return;
  }
  await showDialog<void>(
    context: context,
    animationStyle: AppMotion.overlayStyle(context),
    barrierDismissible: false,
    builder: (_) => _CompanionTextDialog(service: service, interaction: interaction, session: receipt.details),
  );
}

class _CompanionTextDialog extends StatefulWidget {
  const _CompanionTextDialog({required this.service, required this.interaction, required this.session});
  final CompanionController service;
  final CompanionInteraction interaction;
  final Map<String, Object?> session;
  @override
  State<_CompanionTextDialog> createState() => _CompanionTextDialogState();
}

class _CompanionTextDialogState extends State<_CompanionTextDialog> {
  late final TextEditingController _editor;
  Timer? _debounce;
  Future<void> _tail = Future.value();
  int _revision = 0;
  bool _busy = false, _finished = false;
  String? _error;
  String _sent = '';
  Map<String, Object?> get _session => {'sessionId': widget.session['sessionId'], 'generation': widget.session['generation']};
  @override
  void initState() {
    super.initState();
    _editor = TextEditingController(text: widget.session['text'] as String? ?? '');
    _sent = _editor.text;
    _editor.addListener(_changed);
  }

  void _changed() {
    _debounce?.cancel();
    final composing = _editor.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    _debounce = Timer(const Duration(milliseconds: 250), () => _update(_editor.text).ignore());
  }

  Future<CompanionReceipt> _command(CompanionCommandType type, Map<String, Object?> args) =>
      widget.service.interactionCommand(widget.interaction, type, arguments: args);
  Future<void> _update(String text) {
    final task = _tail.then((_) async {
      if (_finished || text == _sent) return;
      final result = await _command(CompanionCommandType.updateTextInput, {..._session, 'revision': ++_revision, 'text': text});
      if (result.phase != CompanionCommandPhase.applied) throw CompanionFailure(result.code ?? 'text_context_changed');
      _sent = text;
    });
    _tail = task.catchError((Object error) {
      if (mounted) setState(() => _error = companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'));
    });
    return task;
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    _debounce?.cancel();
    try {
      await _update(_editor.text);
      final result = await _command(CompanionCommandType.submitTextInput, _session);
      if (result.phase != CompanionCommandPhase.applied) throw CompanionFailure(result.code ?? 'text_context_changed');
      _finished = true;
      if (mounted) Navigator.pop(context);
    } on Object catch (error) {
      if (mounted) setState(() => _error = companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    if (_busy) return;
    setState(() => _busy = true);
    _debounce?.cancel();
    try {
      await _tail;
      await _command(CompanionCommandType.cancelTextInput, _session).timeout(const Duration(seconds: 3));
    } on Object {
      /* A disconnected receiver restores its own session independently. */
    } finally {
      _finished = true;
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _editor.removeListener(_changed);
    _editor.dispose();
    if (!_finished) {
      _command(CompanionCommandType.cancelTextInput, _session).ignore();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: _finished,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_cancel());
    },
    child: AlertDialog(
      scrollable: true,
      title: const Text('输入 TV 搜索词'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('中文输入法组词留在手机，完成的文字会显示在 TV。提交前不会搜索。'),
            TextField(
              controller: _editor,
              autofocus: true,
              maxLength: 256,
              enabled: !_busy,
              decoration: const InputDecoration(hintText: '电影、剧集或搜索词'),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) Text(_error!),
            if (_busy) const LinearProgressIndicator(),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : _cancel, child: const Text('取消并恢复')),
        FilledButton(onPressed: _busy ? null : _submit, child: const Text('提交搜索')),
      ],
    ),
  );
}
