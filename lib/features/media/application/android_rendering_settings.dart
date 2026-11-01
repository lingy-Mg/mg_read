/// Typed bridge to device-local Android renderer launch preferences.
/// Native storage is authoritative because the selection must be available
/// before Flutter/Dart starts. Selecting never changes a live engine; snapshots
/// distinguish the saved choice from the current process and restart need.
library;

import 'package:flutter/services.dart';

enum AndroidRendererMode {
  automatic('auto'),
  openGl('opengl'),
  vulkan('vulkan');

  const AndroidRendererMode(this.id);
  final String id;
}

final class AndroidRenderingSnapshot {
  AndroidRenderingSnapshot.fromMap(Map<String, dynamic> map)
    : selected = AndroidRendererMode.values.firstWhere((value) => value.id == map['selected']),
      activeRenderer = map['activeRenderer'] as String,
      restartRequired = map['restartRequired'] as bool {
    if (!const {'system', 'opengl', 'vulkan'}.contains(activeRenderer)) {
      throw const FormatException('Unknown active Android renderer.');
    }
  }

  final AndroidRendererMode selected;
  final String activeRenderer;
  final bool restartRequired;
}

final class AndroidRenderingSettings {
  const AndroidRenderingSettings();
  static const _channel = MethodChannel('mgread/rendering_settings');

  Future<AndroidRenderingSnapshot> load() => _invoke('get');

  Future<AndroidRenderingSnapshot> select(AndroidRendererMode mode) => _invoke('select', {'mode': mode.id});

  Future<AndroidRenderingSnapshot> _invoke(String method, [Map<String, Object>? arguments]) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(method, arguments).timeout(const Duration(seconds: 3));
    if (result == null) throw const FormatException('Missing Android renderer settings.');
    return AndroidRenderingSnapshot.fromMap(result);
  }
}
