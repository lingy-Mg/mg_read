import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

abstract class ReaderPlatform extends PlatformInterface {
  ReaderPlatform() : super(token: _token);

  static final Object _token = Object();
  static ReaderPlatform _instance = MethodChannelReaderPlatform();

  static ReaderPlatform get instance => _instance;

  static set instance(ReaderPlatform value) {
    PlatformInterface.verifyToken(value, _token);
    _instance = value;
  }

  /// Private platform capability result. Unsupported platforms never receive a channel call.
  Future<ReaderPlatformCapabilities> capabilities() async =>
      const ReaderPlatformCapabilities();

  Future<void> setReaderSystemUi({
    required bool keepScreenOn,
    required bool immersiveMode,
  }) {
    throw UnimplementedError('setReaderSystemUi() has not been implemented.');
  }

  bool get supportsKeepScreenOn => false;

  /// Compatibility shorthand for existing platform fakes and clients.
  Future<void> setKeepScreenOn(bool enabled) =>
      setReaderSystemUi(keepScreenOn: enabled, immersiveMode: false);
}

@immutable
class ReaderPlatformCapabilities {
  const ReaderPlatformCapabilities({
    this.keepScreenOn = false,
    this.immersiveMode = false,
  });
  final bool keepScreenOn;
  final bool immersiveMode;
}

class MethodChannelReaderPlatform extends ReaderPlatform {
  static const MethodChannel _channel = MethodChannel('novel_reader_ui/system');

  @override
  bool get supportsKeepScreenOn =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows);

  @override
  Future<ReaderPlatformCapabilities> capabilities() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.windows)) {
      return const ReaderPlatformCapabilities();
    }
    final Map<Object?, Object?>? result = await _channel
        .invokeMapMethod<Object?, Object?>('getCapabilities');
    return ReaderPlatformCapabilities(
      keepScreenOn: result?['keepScreenOn'] == true,
      immersiveMode: result?['immersiveMode'] == true,
    );
  }

  @override
  Future<void> setReaderSystemUi({
    required bool keepScreenOn,
    required bool immersiveMode,
  }) {
    return _channel.invokeMethod<void>('setReaderSystemUi', <String, bool>{
      'keepScreenOn': keepScreenOn,
      'immersiveMode': immersiveMode,
    });
  }

  @override
  Future<void> setKeepScreenOn(bool enabled) =>
      setReaderSystemUi(keepScreenOn: enabled, immersiveMode: false);
}
