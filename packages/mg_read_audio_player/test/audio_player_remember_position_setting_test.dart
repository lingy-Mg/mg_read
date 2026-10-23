/// Host-owned audio resume preference controls, including failed updates and
/// compact layouts. No media backend or storage is created by this surface.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mg_read_audio_player/src/ui/audio_playback_settings_sheet.dart';

void main() {
  for (final initial in <bool>[true, false]) {
    testWidgets('remember-position switch forwards changes from $initial', (
      tester,
    ) async {
      final changes = <bool>[];
      await _open(
        tester,
        initial: initial,
        onChanged: (enabled) async => changes.add(enabled),
      );
      final toggle = find.byKey(const Key('audio-remember-position-switch'));
      expect(tester.widget<Switch>(toggle).value, initial);
      await tester.tap(toggle);
      await tester.pump();
      expect(changes, <bool>[!initial]);
      expect(tester.widget<Switch>(toggle).value, !initial);
    });
  }

  testWidgets('failed change rolls back and prevents overlapping requests', (
    tester,
  ) async {
    final gate = Completer<void>();
    await _open(tester, initial: true, onChanged: (_) => gate.future);
    final toggle = find.byKey(const Key('audio-remember-position-switch'));
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.widget<Switch>(toggle).value, isFalse);
    expect(tester.widget<Switch>(toggle).onChanged, isNull);
    gate.completeError(StateError('host rejected setting'));
    await tester.pump();
    expect(tester.widget<Switch>(toggle).value, isTrue);
    expect(tester.widget<Switch>(toggle).onChanged, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('standalone host without the capability hides the switch', (
    tester,
  ) async {
    await _open(tester, initial: true);
    expect(
      find.byKey(const Key('audio-remember-position-switch')),
      findsNothing,
    );
  });

  for (final fails in <bool>[false, true]) {
    testWidgets(
      'closing the sheet during a pending update is safe, fails=$fails',
      (tester) async {
        final gate = Completer<void>();
        await _open(tester, initial: true, onChanged: (_) => gate.future);
        await tester.tap(
          find.byKey(const Key('audio-remember-position-switch')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('audio-settings-done')));
        await tester.pumpAndSettle();
        if (fails) {
          gate.completeError(StateError('late settings failure'));
        } else {
          gate.complete();
        }
        await tester.pump();
        expect(find.byKey(const Key('audio-settings-sheet')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'compact screen with large text can reach controls and completion',
    (tester) async {
      await _open(
        tester,
        initial: true,
        onChanged: (_) async {},
        size: const Size(360, 640),
        textScale: 1.5,
      );
      final toggle = find.byKey(const Key('audio-remember-position-switch'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pump();
      expect(tester.widget<Switch>(toggle).value, isFalse);
      await tester.ensureVisible(find.byKey(const Key('audio-timer-off')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('audio-settings-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio-settings-sheet')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _open(
  WidgetTester tester, {
  required bool initial,
  Future<void> Function(bool)? onChanged,
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = AudioPlayerController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showAudioPlaybackSettingsSheet(
            context,
            snapshot: AudioPlayerSnapshot(
              status: AudioPlayerStatus.ready,
              queue: <AudioTrack>[],
            ),
            controller: controller,
            keepScreenOn: true,
            rememberPosition: initial,
            onRememberPositionChanged: onChanged,
          ),
          child: const Text('打开设置'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开设置'));
  await tester.pumpAndSettle();
}
