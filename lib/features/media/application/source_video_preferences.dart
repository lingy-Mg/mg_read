/// Host-owned durable playback preferences. Changes apply to the next route,
/// never to a live decoder. Coupled edits are one settings transaction so a
/// direct hardware surface and software decoding cannot be selected together.
library;

import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';

final class SourceVideoPreferences {
  SourceVideoPreferences.fromSettings(AppSettingsManager settings)
    : decoderMode = switch (settings.get(AppSettingKeys.videoDecoderMode)) {
        'hardware' => VideoDecoderMode.hardware,
        'software' => VideoDecoderMode.software,
        _ => VideoDecoderMode.automatic,
      },
      androidOutputMode = switch (settings.get(AppSettingKeys.videoAndroidOutputMode)) {
        'gpu' => VideoAndroidOutputMode.gpu,
        'surface' => VideoAndroidOutputMode.directSurface,
        _ => VideoAndroidOutputMode.automatic,
      };

  final VideoDecoderMode decoderMode;
  final VideoAndroidOutputMode androidOutputMode;
}

Future<void> setSourceVideoDecoderPreference(AppSettingsManager settings, String value) => settings.transaction((editor) {
  editor.set(AppSettingKeys.videoDecoderMode, value);
  if (value == 'software' && settings.get(AppSettingKeys.videoAndroidOutputMode) == 'surface') {
    editor.set(AppSettingKeys.videoAndroidOutputMode, 'gpu');
  }
});

Future<void> setSourceVideoOutputPreference(AppSettingsManager settings, String value) => settings.transaction((editor) {
  editor.set(AppSettingKeys.videoAndroidOutputMode, value);
  if (value == 'surface' && settings.get(AppSettingKeys.videoDecoderMode) == 'software') {
    editor.set(AppSettingKeys.videoDecoderMode, 'hardware');
  }
});
