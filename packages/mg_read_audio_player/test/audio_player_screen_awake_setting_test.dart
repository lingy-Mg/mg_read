/// Persisted host preference wiring in the playback settings sheet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mg_read_audio_player/src/ui/audio_playback_settings_sheet.dart';

void main() {
  testWidgets('screen-awake control starts enabled and forwards changes', (
    tester,
  ) async {
    final changed = <bool>[];
    final controller = AudioPlayerController();
    addTearDown(controller.dispose);
    final snapshot = AudioPlayerSnapshot(
      status: AudioPlayerStatus.ready,
      queue: <AudioTrack>[],
      rate: 1,
      volume: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAudioPlaybackSettingsSheet(
              context,
              snapshot: snapshot,
              controller: controller,
              keepScreenOn: true,
              onKeepScreenOnChanged: (enabled) async => changed.add(enabled),
            ),
            child: const Text('打开设置'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('audio-keep-screen-on-switch'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(toggle).value, isTrue);
    expect(find.textContaining('手动锁屏后仍会继续后台播放'), findsOneWidget);

    await tester.tap(toggle);
    await tester.pump();

    expect(changed, <bool>[false]);
    expect(tester.widget<Switch>(toggle).value, isFalse);
  });
}
