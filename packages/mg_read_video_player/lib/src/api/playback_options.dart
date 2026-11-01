/// Host-selected decoder and Android video output policies, sampled per backend.
/// Defaults retain platform and device compatibility choices; software decoding
/// always uses GPU output because a direct MediaCodec surface requires hardware.
library;

/// Preferred video decoding policy.
enum VideoDecoderMode {
  /// Retains platform defaults and host-selected hardware compatibility.
  automatic,

  /// Prefers the platform hardware decoder.
  hardware,

  /// Disables hardware video decoding.
  software,
}

/// Android video output policy, independent of the application's UI renderer.
enum VideoAndroidOutputMode {
  /// Allows the host's device compatibility preference to choose the output.
  automatic,

  /// Uses mpv's GPU video output.
  gpu,

  /// Sends hardware-decoded frames directly to Android's video surface.
  directSurface,
}
