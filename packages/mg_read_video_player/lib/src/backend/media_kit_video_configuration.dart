/// Maps public playback choices to MediaKit without exposing native parameters.
/// Android direct surfaces require MediaCodec hardware decoding. Software wins
/// over a conflicting stored surface preference; other platforms ignore Android
/// output policy and retain their own video output defaults.
library;

import 'package:flutter/foundation.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../api/playback_options.dart';

/// Resolves a valid native decoder/output combination for one playback session.
VideoControllerConfiguration mediaKitVideoConfiguration({
  required TargetPlatform platform,
  required bool preferAndroidSurface,
  required VideoDecoderMode decoderMode,
  required VideoAndroidOutputMode androidOutputMode,
}) {
  final android = platform == TargetPlatform.android;
  final direct =
      android &&
      decoderMode != VideoDecoderMode.software &&
      switch (androidOutputMode) {
        VideoAndroidOutputMode.automatic => preferAndroidSurface,
        VideoAndroidOutputMode.gpu => false,
        VideoAndroidOutputMode.directSurface => true,
      };
  return VideoControllerConfiguration(
    vo: android ? (direct ? 'mediacodec_embed' : 'gpu') : null,
    hwdec: direct
        ? 'mediacodec'
        : switch (decoderMode) {
            VideoDecoderMode.automatic => null,
            VideoDecoderMode.hardware => android ? 'mediacodec-copy' : 'auto',
            VideoDecoderMode.software => 'no',
          },
  );
}
