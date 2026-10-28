part of '../mgread_plugin_runtime.dart';

final _androidSystemProxyEvents = const EventChannel(
  'mgread_plugin_runtime/android/system_proxy',
).receiveBroadcastStream();

/// Current system route followed by Android proxy changes, including removal.
/// Multiple consumers share one platform subscription. This never selects or
/// starts a Runtime backend; explicit process environment overrides still win.
Stream<Map<String, String>> watchSystemProxyEnvironment() {
  if (!Platform.isAndroid ||
      const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME')) {
    return Stream.fromFuture(readSystemProxyEnvironment());
  }
  return Stream<Map<String, String>>.multi((controller) {
    var receivedEvent = false;
    var cancelled = false;
    final subscription = _androidSystemProxyEvents.listen(
      (raw) {
        receivedEvent = true;
        final platform = raw is Map
            ? Map<String, String>.from(raw)
            : <String, String>{};
        controller.add(_mergeSystemProxyEnvironment(platform));
      },
      onError: (Object error, StackTrace stack) {
        if (error is! MissingPluginException) controller.addError(error, stack);
      },
    );
    // A shared EventChannel does not replay its initial event to late listeners.
    // Subscribe first, then sample; never overwrite a newer event with this read.
    unawaited(
      readSystemProxyEnvironment().then((environment) {
        if (!receivedEvent && !cancelled) controller.add(environment);
      }),
    );
    controller.onCancel = () async {
      cancelled = true;
      await subscription.cancel();
    };
  }).distinct(mapEquals);
}

Map<String, String> _mergeSystemProxyEnvironment(Map<String, String> platform) {
  final values = <String, String>{...platform};
  for (final name in const ['HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY']) {
    final value = _environmentValueIgnoringCase(Platform.environment, name);
    if (value != null && value.isNotEmpty) values[name] = value;
  }
  _ensureLoopbackNoProxy(values);
  return Map<String, String>.unmodifiable(values);
}

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
