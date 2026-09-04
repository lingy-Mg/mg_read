part of mgread_plugin_runtime;

/// Reads the Windows Internet Settings manual proxy without launching a helper
/// process. PAC/WPAD is intentionally not flattened into a false global value:
/// it is target-URL dependent and needs a dedicated Runtime capability.
final class _WindowsSystemProxy {
  static Map<String, String> environment() {
    if (!Platform.isWindows) return const <String, String>{};

    final memory = _WindowsProxyKernel32.instance.allocate(
      sizeOf<_WinHttpCurrentUserIeProxyConfig>(),
    );
    if (memory.address == 0) return const <String, String>{};
    final config = memory.cast<_WinHttpCurrentUserIeProxyConfig>();
    try {
      try {
        if (!_WinHttp.instance.getCurrentUserIeProxyConfig(config)) {
          return const <String, String>{};
        }
        final proxy = _wideString(config.ref.proxy);
        final bypass = _wideString(config.ref.proxyBypass);
        return _toNodeEnvironment(proxy, bypass);
      } on Object {
        // Proxy discovery must not prevent a packaged Runtime from starting.
        return const <String, String>{};
      } finally {
        _WindowsProxyKernel32.instance.globalFree(config.ref.autoConfigUrl);
        _WindowsProxyKernel32.instance.globalFree(config.ref.proxy);
        _WindowsProxyKernel32.instance.globalFree(config.ref.proxyBypass);
      }
    } finally {
      _WindowsProxyKernel32.instance.free(memory);
    }
  }

  static Map<String, String> _toNodeEnvironment(String? proxy, String? bypass) {
    if (proxy == null || proxy.isEmpty) return const <String, String>{};
    final values = <String, String>{};
    final segments = proxy.split(';').map((item) => item.trim());
    var isPerScheme = false;
    for (final segment in segments) {
      final separator = segment.indexOf('=');
      if (separator <= 0) continue;
      isPerScheme = true;
      final scheme = segment.substring(0, separator).trim().toLowerCase();
      final endpoint = _httpProxyUri(segment.substring(separator + 1));
      if (endpoint == null) continue;
      switch (scheme) {
        case 'http':
          values['HTTP_PROXY'] = endpoint;
        case 'https':
          values['HTTPS_PROXY'] = endpoint;
      }
    }
    if (!isPerScheme) {
      final endpoint = _httpProxyUri(proxy);
      if (endpoint != null) {
        values['HTTP_PROXY'] = endpoint;
        values['HTTPS_PROXY'] = endpoint;
      }
    }
    final noProxy = _noProxyValue(bypass);
    if (noProxy != null) values['NO_PROXY'] = noProxy;
    return values;
  }

  static String? _httpProxyUri(String value) {
    final candidate = value.trim();
    if (candidate.isEmpty) return null;
    final uri = Uri.tryParse(
      candidate.contains('://') ? candidate : 'http://$candidate',
    );
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return uri.toString();
  }

  static String? _noProxyValue(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final values = <String>[
      for (final item in value.split(';'))
        if (item.trim().toLowerCase() == '<local>') ...<String>[
          'localhost',
          '127.0.0.1',
          '::1',
        ] else if (item.trim().isNotEmpty)
          item.trim(),
    ];
    return values.isEmpty ? null : values.join(',');
  }
}

String? _wideString(Pointer<Uint16> pointer) {
  if (pointer.address == 0) return null;
  final units = <int>[];
  for (var index = 0; ; index += 1) {
    final value = (pointer + index).value;
    if (value == 0) return String.fromCharCodes(units);
    units.add(value);
  }
}

final class _WinHttpCurrentUserIeProxyConfig extends Struct {
  @Int32()
  external int autoDetect;

  external Pointer<Uint16> autoConfigUrl;
  external Pointer<Uint16> proxy;
  external Pointer<Uint16> proxyBypass;
}

final class _WinHttp {
  _WinHttp._(DynamicLibrary library)
    : _getCurrentUserIeProxyConfig = library
          .lookupFunction<
            _WinHttpGetIeProxyConfigNative,
            _WinHttpGetIeProxyConfigDart
          >('WinHttpGetIEProxyConfigForCurrentUser');

  static final _WinHttp instance = _WinHttp._(
    DynamicLibrary.open('winhttp.dll'),
  );

  final _WinHttpGetIeProxyConfigDart _getCurrentUserIeProxyConfig;

  bool getCurrentUserIeProxyConfig(
    Pointer<_WinHttpCurrentUserIeProxyConfig> config,
  ) => _getCurrentUserIeProxyConfig(config) != 0;
}

final class _WindowsProxyKernel32 {
  _WindowsProxyKernel32._(DynamicLibrary library)
    : _getProcessHeap = library
          .lookupFunction<
            _WindowsProxyGetProcessHeapNative,
            _WindowsProxyGetProcessHeapDart
          >('GetProcessHeap'),
      _heapAlloc = library
          .lookupFunction<
            _WindowsProxyHeapAllocNative,
            _WindowsProxyHeapAllocDart
          >('HeapAlloc'),
      _heapFree = library
          .lookupFunction<
            _WindowsProxyHeapFreeNative,
            _WindowsProxyHeapFreeDart
          >('HeapFree'),
      _globalFree = library
          .lookupFunction<
            _WindowsProxyGlobalFreeNative,
            _WindowsProxyGlobalFreeDart
          >('GlobalFree');

  static const _heapZeroMemory = 0x00000008;
  static final _WindowsProxyKernel32 instance = _WindowsProxyKernel32._(
    DynamicLibrary.open('kernel32.dll'),
  );

  final _WindowsProxyGetProcessHeapDart _getProcessHeap;
  final _WindowsProxyHeapAllocDart _heapAlloc;
  final _WindowsProxyHeapFreeDart _heapFree;
  final _WindowsProxyGlobalFreeDart _globalFree;

  Pointer<Void> allocate(int byteCount) {
    final heap = _getProcessHeap();
    return heap == 0
        ? Pointer<Void>.fromAddress(0)
        : _heapAlloc(heap, _heapZeroMemory, byteCount);
  }

  void free(Pointer<Void> pointer) {
    if (pointer.address == 0) return;
    final heap = _getProcessHeap();
    if (heap != 0) _heapFree(heap, 0, pointer);
  }

  void globalFree(Pointer<Uint16> pointer) {
    if (pointer.address != 0) _globalFree(pointer.cast<Void>());
  }
}

typedef _WinHttpGetIeProxyConfigNative =
    Int32 Function(Pointer<_WinHttpCurrentUserIeProxyConfig>);
typedef _WinHttpGetIeProxyConfigDart =
    int Function(Pointer<_WinHttpCurrentUserIeProxyConfig>);
typedef _WindowsProxyGetProcessHeapNative = IntPtr Function();
typedef _WindowsProxyGetProcessHeapDart = int Function();
typedef _WindowsProxyHeapAllocNative =
    Pointer<Void> Function(IntPtr, Uint32, IntPtr);
typedef _WindowsProxyHeapAllocDart = Pointer<Void> Function(int, int, int);
typedef _WindowsProxyHeapFreeNative =
    Int32 Function(IntPtr, Uint32, Pointer<Void>);
typedef _WindowsProxyHeapFreeDart = int Function(int, int, Pointer<Void>);
typedef _WindowsProxyGlobalFreeNative = IntPtr Function(Pointer<Void>);
typedef _WindowsProxyGlobalFreeDart = int Function(Pointer<Void>);
