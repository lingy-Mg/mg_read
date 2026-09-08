/// Screen-awake preference and lease ownership tests for active audio.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';

import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/media/application/source_audio_playback_lifecycle.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('default preference keeps playing screen awake and persists opt-out', () async {
    final store = FakeSettingsStore();
    final settings = AppSettingsManager(
      store: store,
      registry: AppSettingKeys.registry,
      policy: const SettingsPersistencePolicy(debounce: Duration.zero),
    );
    await settings.initialize();
    addTearDown(settings.close);
    final controller = _SnapshotAudioController();
    addTearDown(controller.dispose);
    final screen = _RecordingScreenAwakePort();
    final lifecycle = SourceAudioPlaybackLifecycle(
      controller: controller,
      settings: settings,
      screenAwakePort: screen,
      initialLifecycleState: AppLifecycleState.resumed,
    );
    addTearDown(lifecycle.dispose);

    expect(lifecycle.keepScreenOn, isTrue);
    controller.publish(AudioPlayerSnapshot(status: AudioPlayerStatus.ready, queue: <AudioTrack>[], playing: true));
    expect(screen.acquireCalls, 1);

    lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(screen.releaseCalls, 1);
    expect(controller.snapshot.playing, isTrue);

    lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(screen.acquireCalls, 2);
    await lifecycle.setKeepScreenOn(false);
    expect(lifecycle.keepScreenOn, isFalse);
    expect(screen.releaseCalls, 2);
    expect(settings.get(AppSettingKeys.audioKeepScreenOn), isFalse);

    await settings.flush();
    expect(store.documents[AppSettingKeys.mediaPlaybackDocument.kind]?.values[AppSettingKeys.audioKeepScreenOn.id], isFalse);
  });
}

final class _SnapshotAudioController extends AudioPlayerController {
  AudioPlayerSnapshot _current = AudioPlayerSnapshot.initial();

  @override
  AudioPlayerSnapshot get snapshot => _current;

  void publish(AudioPlayerSnapshot snapshot) {
    _current = snapshot;
    notifyListeners();
  }
}

final class _RecordingScreenAwakePort implements SourceAudioScreenAwakePort {
  int acquireCalls = 0;
  int releaseCalls = 0;

  @override
  Future<void> acquire(Object holder) async => acquireCalls++;

  @override
  Future<void> release(Object holder) async => releaseCalls++;
}
