/// Durable host preference defaults, atomic coupling and restart-independent
/// round trips. Changing a preference never issues a live playback command.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/media/application/source_video_preferences.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  late FakeSettingsStore store;
  late AppSettingsManager settings;
  setUp(() async {
    store = FakeSettingsStore();
    settings = AppSettingsManager(store: store, registry: AppSettingKeys.registry);
    await settings.initialize();
  });
  tearDown(() => settings.close());

  test('existing installs retain automatic decoding and output', () {
    final preferences = SourceVideoPreferences.fromSettings(settings);
    expect(preferences.decoderMode, VideoDecoderMode.automatic);
    expect(preferences.androidOutputMode, VideoAndroidOutputMode.automatic);
    expect(preferences.adFilterEnabled, isTrue);
  });

  test('global video ad filtering opt-out survives reopening settings', () async {
    await settings.set(AppSettingKeys.videoAdFilterEnabled, false);
    await settings.flush();
    final reopened = AppSettingsManager(store: store, registry: AppSettingKeys.registry);
    await reopened.initialize();
    addTearDown(reopened.close);
    expect(SourceVideoPreferences.fromSettings(reopened).adFilterEnabled, isFalse);
  });

  test('software and direct surface choices persist as valid atomic pairs', () async {
    await setSourceVideoOutputPreference(settings, 'surface');
    await setSourceVideoDecoderPreference(settings, 'software');
    expect(settings.get(AppSettingKeys.videoAndroidOutputMode), 'gpu');
    await setSourceVideoOutputPreference(settings, 'surface');
    expect(settings.get(AppSettingKeys.videoDecoderMode), 'hardware');
    await settings.flush();

    final reopened = AppSettingsManager(store: store, registry: AppSettingKeys.registry);
    await reopened.initialize();
    addTearDown(reopened.close);
    final preferences = SourceVideoPreferences.fromSettings(reopened);
    expect(preferences.decoderMode, VideoDecoderMode.hardware);
    expect(preferences.androidOutputMode, VideoAndroidOutputMode.directSurface);
  });

  test('invalid choices do not partially mutate the preference pair', () async {
    await expectLater(setSourceVideoDecoderPreference(settings, 'unknown'), throwsArgumentError);
    await expectLater(setSourceVideoOutputPreference(settings, 'unknown'), throwsArgumentError);
    expect(settings.get(AppSettingKeys.videoDecoderMode), 'auto');
    expect(settings.get(AppSettingKeys.videoAndroidOutputMode), 'auto');
  });
}
