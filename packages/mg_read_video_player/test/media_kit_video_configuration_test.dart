/// Verifies public playback choices and invalid-combination safety before any
/// native player is constructed. Native rendering is covered by device tests.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';
import 'package:mg_read_video_player/src/backend/media_kit_video_configuration.dart';

void main() {
  test('automatic keeps the verified Android device surface policy', () {
    final config = mediaKitVideoConfiguration(
      platform: TargetPlatform.android,
      preferAndroidSurface: true,
      decoderMode: VideoDecoderMode.automatic,
      androidOutputMode: VideoAndroidOutputMode.automatic,
    );
    expect(config.vo, 'mediacodec_embed');
    expect(config.hwdec, 'mediacodec');
  });

  test('explicit GPU overrides the device surface preference', () {
    final config = mediaKitVideoConfiguration(
      platform: TargetPlatform.android,
      preferAndroidSurface: true,
      decoderMode: VideoDecoderMode.automatic,
      androidOutputMode: VideoAndroidOutputMode.gpu,
    );
    expect(config.vo, 'gpu');
    expect(config.hwdec, isNull);
  });

  test('software decoding cannot accidentally use a hardware-only surface', () {
    final config = mediaKitVideoConfiguration(
      platform: TargetPlatform.android,
      preferAndroidSurface: true,
      decoderMode: VideoDecoderMode.software,
      androidOutputMode: VideoAndroidOutputMode.directSurface,
    );
    expect(config.vo, 'gpu');
    expect(config.hwdec, 'no');
  });

  test('Android hardware GPU output chooses the copy-capable codec', () {
    final config = mediaKitVideoConfiguration(
      platform: TargetPlatform.android,
      preferAndroidSurface: false,
      decoderMode: VideoDecoderMode.hardware,
      androidOutputMode: VideoAndroidOutputMode.gpu,
    );
    expect(config.vo, 'gpu');
    expect(config.hwdec, 'mediacodec-copy');
  });

  test(
    'desktop output ignores Android-only settings but honors software decoding',
    () {
      final config = mediaKitVideoConfiguration(
        platform: TargetPlatform.windows,
        preferAndroidSurface: true,
        decoderMode: VideoDecoderMode.software,
        androidOutputMode: VideoAndroidOutputMode.directSurface,
      );
      expect(config.vo, isNull);
      expect(config.hwdec, 'no');
    },
  );
}
