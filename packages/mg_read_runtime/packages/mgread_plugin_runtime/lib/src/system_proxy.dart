part of mgread_plugin_runtime;

/// Returns the current platform proxy as the environment shape understood by
/// Dart and Node HTTP clients.
///
/// Process `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` values take precedence.
/// Windows manual Internet Settings and Android's active network proxy fill
/// only missing values. Loopback destinations are always excluded.
Future<Map<String, String>> readSystemProxyEnvironment() async {
  final values = <String, String>{};
  for (final name in const <String>['HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY']) {
    final value = _environmentValueIgnoringCase(Platform.environment, name);
    if (value != null && value.isNotEmpty) values[name] = value;
  }
  if (Platform.isWindows) {
    for (final entry in _WindowsSystemProxy.environment().entries) {
      values.putIfAbsent(entry.key, () => entry.value);
    }
  } else if (Platform.isAndroid) {
    try {
      final raw = await _androidRuntimeChannel.invokeMapMethod<String, String>(
        'readSystemProxyEnvironment',
      );
      if (raw != null) {
        for (final entry in raw.entries) {
          if (entry.value.isNotEmpty) {
            values.putIfAbsent(entry.key.toUpperCase(), () => entry.value);
          }
        }
      }
    } on Object {
      // System proxy discovery must never block application startup.
    }
  }
  _ensureLoopbackNoProxy(values);
  return Map<String, String>.unmodifiable(values);
}

void _ensureLoopbackNoProxy(Map<String, String> environment) {
  final existing = _environmentValueIgnoringCase(environment, 'NO_PROXY');
  final entries = <String>{
    if (existing != null)
      for (final item in existing.split(','))
        if (item.trim().isNotEmpty) item.trim(),
    'localhost',
    '127.0.0.1',
    '::1',
  };
  environment.remove('no_proxy');
  environment['NO_PROXY'] = entries.join(',');
}
