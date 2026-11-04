part of mgread_plugin_runtime;

/// Desktop JS hosts share source data but only one runs in each App process.
enum DesktopRuntimeBackend { node, bun }

/// Owns the desktop launch preference, not main-application business settings.
/// Initialize before creating the Facade. Atomic saves affect the next process
/// only; a missing Bun helper disables its selection and recovers to Node.
final class DesktopRuntimeSettings {
  DesktopRuntimeSettings._();

  @visibleForTesting
  DesktopRuntimeSettings.forTesting({
    required File preferenceFile,
    required bool supportsBun,
  }) : _preferenceFile = preferenceFile,
       _supportsBun = supportsBun;

  static final instance = DesktopRuntimeSettings._();
  static const bunVersion = '1.4.4';
  Future<void>? _initialization;
  Future<void> _saving = Future<void>.value();
  File? _preferenceFile;
  bool _supportsBun = false;
  DesktopRuntimeBackend _active = DesktopRuntimeBackend.node;
  DesktopRuntimeBackend _selected = DesktopRuntimeBackend.node;

  DesktopRuntimeBackend get active => _active;
  DesktopRuntimeBackend get selected => _selected;
  bool get supportsBun => _supportsBun;
  bool get restartRequired => _selected != _active;

  Future<void> initialize() => _initialization ??= _load();

  Future<void> _load() async {
    if (_preferenceFile == null) {
      final bundle = _DesktopRuntimeBundle.fromApplicationPackage(
        backend: DesktopRuntimeBackend.bun,
      );
      _preferenceFile = File(
        _joinPath([bundle.dataRoot.path, 'desktop-backend.txt']),
      );
      _supportsBun = await bundle.nodeExecutable.exists();
    }
    String? stored;
    try {
      stored = (await _preferenceFile!.readAsString()).trim();
    } on FormatException {
      // Invalid UTF-8 is a damaged preference, never a reason to lose access
      // to settings or to the bundled Node recovery option.
      stored = null;
    } on FileSystemException {
      // A missing/unreadable launch preference must not prevent the App from
      // opening. Subsequent save errors remain visible in the settings page.
      stored = null;
    }
    _selected = stored == 'bun' && _supportsBun
        ? DesktopRuntimeBackend.bun
        : DesktopRuntimeBackend.node;
    _active = _selected;
  }

  Future<void> select(DesktopRuntimeBackend backend) {
    final operation = _saving.then((_) async {
      await initialize();
      if (backend == DesktopRuntimeBackend.bun && !_supportsBun) {
        throw UnsupportedError('This installation does not include Bun');
      }
      final file = _preferenceFile!;
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.next');
      try {
        await temporary.writeAsString('${backend.name}\n', flush: true);
        await temporary.rename(file.path);
      } catch (_) {
        if (await temporary.exists()) await temporary.delete();
        rethrow;
      }
      _selected = backend;
    });
    _saving = operation.catchError((Object _) {});
    return operation;
  }
}
