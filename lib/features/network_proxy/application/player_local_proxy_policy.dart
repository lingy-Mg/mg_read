/// Windows process-environment policy used only to control native MediaKit's
/// handling of Runtime loopback URLs.
///
/// mpv/FFmpeg continue to honor `no_proxy` after an explicit `http-proxy` is
/// set. This owner can therefore remove only loopback entries while the user
/// explicitly forces audio/video Runtime URLs through the configured proxy.
/// The original process value is restored when the policy is disabled or the
/// provider is disposed. Other proxy variables are never changed.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'network_proxy_settings.dart';

final playerLocalProxyPolicyControllerProvider = Provider<PlayerLocalProxyPolicyController>((Ref ref) {
  final controller = PlayerLocalProxyPolicyController();
  ref.onDispose(controller.restore);
  return controller;
});

final configuredPlayerLocalProxyPolicyProvider = Provider<PlayerLocalProxyPolicyController>((Ref ref) {
  final controller = ref.watch(playerLocalProxyPolicyControllerProvider);
  controller.update(ref.watch(networkProxySettingsProvider));
  return controller;
});

typedef PlayerProxyEnvironmentWriter = void Function(String name, String? value);

final class PlayerLocalProxyPolicyController {
  PlayerLocalProxyPolicyController()
    : this.forTesting(_environmentValueIgnoringCase(Platform.environment, 'NO_PROXY'), Platform.isWindows, _writeWindowsEnvironment);

  @visibleForTesting
  PlayerLocalProxyPolicyController.forTesting(this._originalNoProxy, this._supported, this._writeEnvironment);

  final String? _originalNoProxy;
  final bool _supported;
  final PlayerProxyEnvironmentWriter _writeEnvironment;
  bool _forcing = false;

  bool get isForcing => _forcing;

  void update(NetworkProxySettings settings) => setForced(settings.shouldForcePlayerLocalProxy);

  @visibleForTesting
  void setForced(bool value) {
    final next = value && _supported;
    if (_forcing == next) return;
    _writeEnvironment('no_proxy', next ? stripLoopbackFromNoProxy(_originalNoProxy) : _originalNoProxy);
    _forcing = next;
  }

  void restore() => setForced(false);
}

@visibleForTesting
String? stripLoopbackFromNoProxy(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final retained = <String>[
    for (final entry in value.split(','))
      if (entry.trim().isNotEmpty && !_matchesRuntimeLoopback(entry.trim())) entry.trim(),
  ];
  return retained.isEmpty ? null : retained.join(',');
}

bool _matchesRuntimeLoopback(String value) {
  var candidate = value.toLowerCase();
  if (candidate == '*') return true;
  if (candidate.startsWith('[')) {
    final boundary = candidate.indexOf(']');
    if (boundary >= 0) candidate = candidate.substring(0, boundary + 1);
  } else if (candidate.indexOf(':') == candidate.lastIndexOf(':')) {
    final separator = candidate.lastIndexOf(':');
    if (separator > 0 && int.tryParse(candidate.substring(separator + 1)) != null) {
      candidate = candidate.substring(0, separator);
    }
  }
  return candidate == 'localhost' ||
      candidate == '.localhost' ||
      candidate == '*.localhost' ||
      candidate == '127.0.0.1' ||
      candidate == '127.0.0.0/8' ||
      candidate == '127.*' ||
      candidate == '::1' ||
      candidate == '[::1]';
}

String? _environmentValueIgnoringCase(Map<String, String> environment, String name) {
  final expected = name.toLowerCase();
  for (final entry in environment.entries) {
    if (entry.key.toLowerCase() == expected) return entry.value;
  }
  return null;
}

void _writeWindowsEnvironment(String name, String? value) {
  if (!Platform.isWindows) return;
  final namePointer = name.toNativeUtf16();
  final valuePointer = (value ?? '').toNativeUtf16();
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final setEnvironmentVariable = kernel32
        .lookupFunction<Int32 Function(Pointer<Utf16>, Pointer<Utf16>), int Function(Pointer<Utf16>, Pointer<Utf16>)>(
          'SetEnvironmentVariableW',
        );
    final win32Result = setEnvironmentVariable(namePointer, value == null ? nullptr : valuePointer);
    var crtResult = 0;
    for (final libraryName in const <String>['ucrtbase.dll', 'msvcrt.dll']) {
      final putEnvironment = DynamicLibrary.open(
        libraryName,
      ).lookupFunction<Int32 Function(Pointer<Utf16>, Pointer<Utf16>), int Function(Pointer<Utf16>, Pointer<Utf16>)>('_wputenv_s');
      crtResult |= putEnvironment(namePointer, valuePointer);
    }
    if (win32Result == 0 || crtResult != 0) {
      throw StateError('The native player proxy bypass environment could not be updated.');
    }
  } finally {
    calloc.free(namePointer);
    calloc.free(valuePointer);
  }
}

@visibleForTesting
Map<String, String?> readWindowsCrtEnvironment(String name) {
  if (!Platform.isWindows) return const <String, String?>{};
  final namePointer = name.toNativeUtf16();
  try {
    return <String, String?>{
      for (final libraryName in const <String>['ucrtbase.dll', 'msvcrt.dll']) libraryName: _readCrtEnvironment(libraryName, namePointer),
    };
  } finally {
    calloc.free(namePointer);
  }
}

String? _readCrtEnvironment(String libraryName, Pointer<Utf16> name) {
  final readEnvironment = DynamicLibrary.open(
    libraryName,
  ).lookupFunction<Pointer<Utf16> Function(Pointer<Utf16>), Pointer<Utf16> Function(Pointer<Utf16>)>('_wgetenv');
  final value = readEnvironment(name);
  return value == nullptr ? null : value.toDartString();
}
