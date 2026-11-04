import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/tv_companion/application/companion_text_input.dart';
import 'package:mg_read/features/tv_companion/domain/companion_models.dart';

void main() {
  late CompanionTextInput input;
  late TextEditingController editor;
  final host = Object();

  setUp(() {
    input = CompanionTextInput();
    editor = TextEditingController(text: 'TV draft');
    input.attach(host, editor, () {});
  });

  tearDown(() {
    input.detach(host);
    editor.dispose();
    input.dispose();
  });

  test('remote full-text revisions update the TV editor and cancel restores the original draft', () {
    final session = input.begin('phone', 'session-1');
    final args = {'sessionId': session['sessionId'], 'generation': session['generation']};
    input.update('phone', {...args, 'revision': 1, 'text': 'Remote search'});
    expect(editor.text, 'Remote search');
    expect(input.value.text, 'Remote search');

    expect(
      () => input.update('phone', {...args, 'revision': 1, 'text': 'out-of-order'}),
      throwsA(isA<CompanionFailure>().having((error) => error.code, 'code', 'text_revision_invalid')),
    );
    input.cancel('phone', args);

    expect(editor.text, 'TV draft');
    expect(input.value.text, 'TV draft');
    expect(input.active, isFalse);
    expect(input.onSubmit, isNotNull);
    expect(
      () => input.update('phone', {...args, 'revision': 2, 'text': 'stale session'}),
      throwsA(isA<CompanionFailure>().having((error) => error.code, 'code', 'text_context_changed')),
    );
  });

  test('a local TV edit fences the phone session and remains visible', () {
    final session = input.begin('phone', 'session-2');
    final args = {'sessionId': session['sessionId'], 'generation': session['generation']};
    input.update('phone', {...args, 'revision': 1, 'text': 'Phone draft'});
    editor.text = 'TV local edit';

    expect(input.active, isFalse);
    expect(input.value.text, 'TV local edit');
    expect(editor.text, 'TV local edit');
    expect(
      () => input.cancel('phone', args),
      throwsA(isA<CompanionFailure>().having((error) => error.code, 'code', 'text_context_changed')),
    );
    expect(editor.text, 'TV local edit');
  });

  test('disconnect restores the pre-session TV draft and invalidates the session generation', () {
    final session = input.begin('phone', 'session-3');
    final args = {'sessionId': session['sessionId'], 'generation': session['generation']};
    input.update('phone', {...args, 'revision': 1, 'text': 'Phone draft'});
    input.disconnect('phone');

    expect(input.active, isFalse);
    expect(editor.text, 'TV draft');
    expect(
      () => input.submit('phone', args),
      throwsA(isA<CompanionFailure>().having((error) => error.code, 'code', 'text_context_changed')),
    );
  });

  test('a hidden host route expires the session and restores its original draft', () {
    var current = true;
    input.attach(host, editor, () {}, isCurrent: () => current);
    final session = input.begin('phone', 'session-hidden-route');
    final args = {'sessionId': session['sessionId'], 'generation': session['generation']};
    input.update('phone', {...args, 'revision': 1, 'text': 'Remote draft'});
    expect(input.attached, isTrue);

    current = false;
    input.expire();

    expect(input.attached, isFalse);
    expect(input.active, isFalse);
    expect(editor.text, 'TV draft');
    expect(
      () => input.update('phone', {...args, 'revision': 2, 'text': 'hidden route'}),
      throwsA(isA<CompanionFailure>().having((error) => error.code, 'code', 'text_context_changed')),
    );
  });
}
