/// Explicit search-only remote text sessions. Composing IME state remains on
/// the phone; local TV edits invalidate the generation instead of being lost.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/companion_models.dart';

final companionTextInputProvider = Provider<CompanionTextInput>((ref) => CompanionTextInput());

final class CompanionTextInput extends ChangeNotifier {
  TextEditingValue _value = TextEditingValue.empty;
  TextEditingValue get value => _value;
  String? _owner, _session;
  int _generation = 0, _revision = 0;
  String _before = '';
  Object? _hostOwner;
  bool Function()? _hostCurrent;
  TextEditingController? _editor;
  bool _applying = false;
  final Stopwatch _clock = Stopwatch()..start();
  int _expiresAtMs = 0;
  bool get attached => _editor != null && (_hostCurrent?.call() ?? true);
  bool get active => _session != null;
  VoidCallback? onSubmit;
  void Function(String)? onChanged;
  void attach(Object owner, TextEditingController editor, VoidCallback submit, {bool Function()? isCurrent}) {
    if (identical(owner, _hostOwner)) {
      _hostCurrent = isCurrent;
      return;
    }
    if (_hostOwner != null) detach(_hostOwner!);
    _hostOwner = owner;
    _hostCurrent = isCurrent;
    _editor = editor;
    _value = editor.value;
    onSubmit = submit;
    onChanged = (text) {
      _applying = true;
      try {
        editor.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      } finally {
        _applying = false;
      }
    };
    editor.addListener(_editorChanged);
  }

  void detach(Object owner) {
    if (!identical(owner, _hostOwner)) return;
    _editor?.removeListener(_editorChanged);
    _editor = null;
    _hostOwner = null;
    _hostCurrent = null;
    onSubmit = null;
    onChanged = null;
    _finish();
  }

  void _editorChanged() {
    if (!_applying && _editor != null) localEdit(_editor!.text);
  }

  Map<String, Object?> begin(String peerId, String sessionId) {
    if (!attached) throw const CompanionFailure('text_context_changed');
    if (_owner != null && _owner != peerId) throw const CompanionFailure('text_input_busy');
    _owner = peerId;
    _session = sessionId;
    _before = _value.text;
    _revision = 0;
    _generation++;
    _expiresAtMs = _clock.elapsedMilliseconds + 60000;
    notifyListeners();
    return _snapshot();
  }

  Map<String, Object?> update(String peerId, Map<String, Object?> args) {
    _check(peerId, args);
    final text = args['text'];
    final revision = args['revision'];
    if (text is! String || text.runes.length > 256 || revision is! int || revision <= _revision) {
      throw const CompanionFailure('text_revision_invalid');
    }
    _revision = revision;
    _expiresAtMs = _clock.elapsedMilliseconds + 60000;
    _value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    onChanged?.call(text);
    notifyListeners();
    return _snapshot();
  }

  void submit(String peerId, Map<String, Object?> args) {
    _check(peerId, args);
    _finish();
    onSubmit?.call();
  }

  void cancel(String peerId, Map<String, Object?> args) {
    _check(peerId, args);
    _value = TextEditingValue(text: _before);
    onChanged?.call(_before);
    _finish();
  }

  void localEdit(String text) {
    if (_value.text == text) return;
    _value = TextEditingValue(text: text);
    _finish();
  }

  void disconnect(String peerId) {
    if (_owner == peerId) {
      _value = TextEditingValue(text: _before);
      onChanged?.call(_before);
      _finish();
    }
  }

  void _check(String peerId, Map<String, Object?> args) {
    expire();
    if (_owner != peerId || _session == null || args['sessionId'] != _session || args['generation'] != _generation) {
      throw const CompanionFailure('text_context_changed');
    }
  }

  void expire() {
    if (_session != null && (!attached || _clock.elapsedMilliseconds >= _expiresAtMs)) {
      _value = TextEditingValue(text: _before);
      onChanged?.call(_before);
      _finish();
    }
  }

  void _finish() {
    _owner = null;
    _session = null;
    _generation++;
    notifyListeners();
  }

  Map<String, Object?> _snapshot() => {'sessionId': _session, 'generation': _generation, 'revision': _revision, 'text': _value.text};
}
