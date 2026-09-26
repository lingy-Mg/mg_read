part of mgread_plugin_runtime;

/// Both Android Node hosts ship together; this choice applies at cold start.
enum AndroidNodeBackend { javet, nodeProcess }

/// Runtime-owned launch preference, persisted by the Android host.
///
/// Initialize before constructing the production Facade. Saving never changes
/// the active supervisor: the application must restart its process to apply it.
/// Unsupported ABIs expose Javet only, even if a preference was restored.
final class AndroidNodeRuntimeSettings {
  AndroidNodeRuntimeSettings();

  static final instance = AndroidNodeRuntimeSettings();
  static const _channel = MethodChannel(
    'mgread_plugin_runtime/android_backend',
  );
  Future<void>? _initialization;
  AndroidNodeBackend _active = AndroidNodeBackend.javet;
  AndroidNodeBackend _selected = AndroidNodeBackend.javet;
  bool _supportsNodeProcess = false;

  AndroidNodeBackend get active => _active;
  AndroidNodeBackend get selected => _selected;
  bool get supportsNodeProcess => _supportsNodeProcess;
  bool get restartRequired => _selected != _active;

  Future<void> initialize() => _initialization ??= _load();

  Future<void> _load() async {
    final value = await _channel.invokeMapMethod<String, Object?>('read');
    if (value == null) throw StateError('Android backend settings unavailable');
    _supportsNodeProcess = value['supportsNodeProcess'] == true;
    _selected = value['selected'] == 'nodeProcess' && _supportsNodeProcess
        ? AndroidNodeBackend.nodeProcess
        : AndroidNodeBackend.javet;
    _active = _selected;
  }

  Future<void> select(AndroidNodeBackend backend) async {
    await initialize();
    if (backend == AndroidNodeBackend.nodeProcess && !_supportsNodeProcess) {
      throw UnsupportedError('This device does not support the Node process');
    }
    await _channel.invokeMethod<void>('select', {'backend': backend.name});
    _selected = backend;
  }
}
