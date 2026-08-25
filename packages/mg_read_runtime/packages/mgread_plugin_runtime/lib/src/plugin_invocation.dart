part of mgread_plugin_runtime;

/// A versioned, typed Runtime capability call.
@immutable
sealed class PluginInvocation<T> {
  const PluginInvocation();

  String get _wireMethod;
  Map<String, Object?> get _wireParams;
  Duration get _timeout => _controlTimeout;
  T _decodeResult(Object? value);
}

/// Minimal Runtime health capability with no transport metadata.
@immutable
final class RuntimePingInvocation extends PluginInvocation<RuntimePingResult> {
  const RuntimePingInvocation();

  @override
  String get _wireMethod => 'runtime.ping';

  @override
  Map<String, Object?> get _wireParams => const <String, Object?>{};

  @override
  RuntimePingResult _decodeResult(Object? value) {
    final result = _jsonObject(value, 'Runtime ping result');
    final ok = result['ok'];
    final nodeVersion = result['nodeVersion'];
    final runtimeVersion = result['runtimeVersion'];
    if (ok is! bool || nodeVersion is! String || runtimeVersion is! String) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime returned an invalid ping result.',
      );
    }
    return RuntimePingResult(
      isHealthy: ok,
      nodeVersion: nodeVersion,
      runtimeVersion: runtimeVersion,
    );
  }
}

@immutable
final class RuntimePingResult {
  const RuntimePingResult({
    required this.isHealthy,
    required this.nodeVersion,
    required this.runtimeVersion,
  });

  final bool isHealthy;
  final String nodeVersion;
  final String runtimeVersion;
}

/// Returns a bounded, path-free snapshot for the Runtime status page.
@immutable
final class RuntimeStatusInvocation
    extends PluginInvocation<RuntimeStatusResult> {
  const RuntimeStatusInvocation();

  @override
  String get _wireMethod => 'runtime.status.v1';

  @override
  Map<String, Object?> get _wireParams => const <String, Object?>{};

  @override
  RuntimeStatusResult _decodeResult(Object? value) {
    final result = _jsonObject(value, 'Runtime status result');
    final memory = _jsonObject(result['memory'], 'Runtime memory result');
    final plugins = result['plugins'];
    final uptimeMs = result['uptimeMs'];
    final ok = result['ok'];
    final nodeVersion = result['nodeVersion'];
    final runtimeVersion = result['runtimeVersion'];
    final runtimeKind = result['runtimeKind'];
    final platform = result['platform'];
    final arch = result['arch'];
    if (ok is! bool ||
        nodeVersion is! String ||
        runtimeVersion is! String ||
        (runtimeKind != 'android-javet' && runtimeKind != 'desktop-node') ||
        platform is! String ||
        arch is! String ||
        uptimeMs is! int ||
        uptimeMs < 0 ||
        plugins is! List<Object?> ||
        plugins.length > 1024) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime returned an invalid status result.',
      );
    }
    return RuntimeStatusResult(
      arch: arch,
      isHealthy: ok,
      memory: RuntimeMemoryUsage(
        arrayBuffers: _nonNegativeInt(memory, 'arrayBuffers'),
        external: _nonNegativeInt(memory, 'external'),
        heapTotal: _nonNegativeInt(memory, 'heapTotal'),
        heapUsed: _nonNegativeInt(memory, 'heapUsed'),
        rss: _nonNegativeInt(memory, 'rss'),
      ),
      nodeVersion: nodeVersion,
      platform: platform,
      plugins: List<InstalledPlugin>.unmodifiable(
        plugins.map(_decodeInstalledPlugin),
      ),
      runtimeVersion: runtimeVersion,
      runtimeKind: runtimeKind as String,
      uptimeMs: uptimeMs,
    );
  }
}

int _nonNegativeInt(Map<String, Object?> object, String key) {
  final value = object[key];
  if (value is! int || value < 0) {
    throw const PluginRuntimeException(
      'invalid_response',
      'The Runtime returned invalid memory usage.',
    );
  }
  return value;
}

@immutable
final class RuntimeStatusResult {
  const RuntimeStatusResult({
    required this.arch,
    required this.isHealthy,
    required this.memory,
    required this.nodeVersion,
    required this.platform,
    required this.plugins,
    required this.runtimeVersion,
    required this.runtimeKind,
    required this.uptimeMs,
  });

  final String arch;
  final bool isHealthy;
  final RuntimeMemoryUsage memory;
  final String nodeVersion;
  final String platform;
  final List<InstalledPlugin> plugins;
  final String runtimeVersion;
  final String runtimeKind;
  final int uptimeMs;
}

@immutable
final class RuntimeMemoryUsage {
  const RuntimeMemoryUsage({
    required this.arrayBuffers,
    required this.external,
    required this.heapTotal,
    required this.heapUsed,
    required this.rss,
  });

  final int arrayBuffers;
  final int external;
  final int heapTotal;
  final int heapUsed;
  final int rss;
}

/// Lists Runtime-owned installed-plugin projections without exposing paths.
@immutable
final class InstalledPluginsInvocation
    extends PluginInvocation<List<InstalledPlugin>> {
  const InstalledPluginsInvocation();

  @override
  String get _wireMethod => 'plugins.list.v1';

  @override
  Map<String, Object?> get _wireParams => const <String, Object?>{};

  @override
  List<InstalledPlugin> _decodeResult(Object? value) {
    if (value is! List<Object?>) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime returned an invalid installed-plugin list.',
      );
    }
    return List<InstalledPlugin>.unmodifiable(
      value.map((Object? raw) {
        return _decodeInstalledPlugin(raw);
      }),
    );
  }
}

/// Consumes the path-free summary of sources isolated during this Runtime start.
@immutable
final class PluginStartupRecoveryInvocation
    extends PluginInvocation<PluginStartupRecovery> {
  const PluginStartupRecoveryInvocation();

  @override
  String get _wireMethod => 'plugins.recovery.consume.v1';

  @override
  Map<String, Object?> get _wireParams => const <String, Object?>{};

  @override
  PluginStartupRecovery _decodeResult(Object? value) {
    final result = _jsonObject(value, 'Plugin startup recovery');
    final quarantinedCount = result['quarantinedCount'];
    if (quarantinedCount is! int || quarantinedCount < 0) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime returned an invalid plugin recovery summary.',
      );
    }
    return PluginStartupRecovery(quarantinedCount: quarantinedCount);
  }
}

@immutable
final class PluginStartupRecovery {
  const PluginStartupRecovery({required this.quarantinedCount});

  final int quarantinedCount;
}

/// Persists a source's desired enabled state in the Runtime-owned plugin store.
@immutable
final class SetPluginEnabledInvocation
    extends PluginInvocation<InstalledPlugin> {
  const SetPluginEnabledInvocation({
    required this.pluginId,
    required this.enabled,
  });

  final String pluginId;
  final bool enabled;

  @override
  String get _wireMethod => 'plugins.setEnabled.v1';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{
    'pluginId': pluginId,
    'enabled': enabled,
  };

  @override
  InstalledPlugin _decodeResult(Object? value) => _decodeInstalledPlugin(value);
}

/// Opens a source code directory through the Runtime-owned Windows action.
///
/// The result intentionally reveals only whether this was a live development
/// project or an immutable installed version. It never contains a file path.
@immutable
final class OpenPluginCodeDirectoryInvocation
    extends PluginInvocation<PluginCodeDirectoryKind> {
  const OpenPluginCodeDirectoryInvocation({required this.pluginId});

  final String pluginId;

  @override
  String get _wireMethod => 'plugins.openCodeDirectory.v1';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{
    'pluginId': pluginId,
  };

  @override
  PluginCodeDirectoryKind _decodeResult(Object? value) {
    final result = _jsonObject(value, 'Plugin code directory result');
    return switch (result['kind']) {
      'development' => PluginCodeDirectoryKind.development,
      'installed' => PluginCodeDirectoryKind.installed,
      _ => throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime returned an invalid plugin code directory result.',
      ),
    };
  }
}

enum PluginCodeDirectoryKind { development, installed }

/// Opens the Runtime-private data root through the Flutter Windows shell action.
///
/// The result is deliberately path-free; Android and other unsupported
/// platforms return a stable `unsupported` Runtime error.
@immutable
final class OpenRuntimePrivateDirectoryInvocation
    extends PluginInvocation<void> {
  const OpenRuntimePrivateDirectoryInvocation();

  @override
  String get _wireMethod => 'runtime.openPrivateDirectory.v1';

  @override
  Map<String, Object?> get _wireParams => const <String, Object?>{};

  @override
  void _decodeResult(Object? value) {
    final result = _jsonObject(value, 'Runtime private directory result');
    if (result['opened'] != true) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime returned an invalid private directory result.',
      );
    }
  }
}

/// Selects which part of an installed source version should be measured.
enum PluginInstallationSizeScope { archive, data, npm }

/// Returns path-free byte totals for one installed source subtree.
@immutable
final class PluginInstallationSizeInvocation
    extends PluginInvocation<PluginInstallationSize> {
  const PluginInstallationSizeInvocation({
    required this.pluginId,
    required this.scope,
  });

  final String pluginId;
  final PluginInstallationSizeScope scope;

  @override
  String get _wireMethod => 'plugins.installation.usage.v1';

  @override
  Duration get _timeout => const Duration(minutes: 2);

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{
    'pluginId': pluginId,
    'scope': switch (scope) {
      PluginInstallationSizeScope.archive => 'archive',
      PluginInstallationSizeScope.data => 'data',
      PluginInstallationSizeScope.npm => 'npm',
    },
  };

  @override
  PluginInstallationSize _decodeResult(Object? value) {
    final result = _jsonObject(value, 'Plugin installation size');
    final pluginId = result['pluginId'];
    final version = result['version'];
    final scope = result['scope'];
    final bytes = result['bytes'];
    final fileCount = result['fileCount'];
    if (pluginId is! String ||
        version is! String ||
        bytes is! int ||
        bytes < 0 ||
        fileCount is! int ||
        fileCount < 0) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime returned an invalid installation size result.',
      );
    }
    final parsedScope = switch (scope) {
      'archive' => PluginInstallationSizeScope.archive,
      'data' => PluginInstallationSizeScope.data,
      'npm' => PluginInstallationSizeScope.npm,
      _ => null,
    };
    if (parsedScope == null) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime returned an invalid installation size scope.',
      );
    }
    return PluginInstallationSize(
      bytes: bytes,
      fileCount: fileCount,
      pluginId: pluginId,
      scope: parsedScope,
      version: version,
    );
  }
}

/// Strong Flutter projection of one installed source size measurement.
@immutable
final class PluginInstallationSize {
  const PluginInstallationSize({
    required this.bytes,
    required this.fileCount,
    required this.pluginId,
    required this.scope,
    required this.version,
  });

  final int bytes;
  final int fileCount;
  final String pluginId;
  final PluginInstallationSizeScope scope;
  final String version;
}

/// Lists Runtime-owned cache byte totals without exposing private directories.
@immutable
final class PluginCacheUsageInvocation
    extends PluginInvocation<List<PluginCacheUsage>> {
  const PluginCacheUsageInvocation();

  @override
  String get _wireMethod => 'plugins.cache.usage.v1';

  @override
  Map<String, Object?> get _wireParams => const <String, Object?>{};

  @override
  List<PluginCacheUsage> _decodeResult(Object? value) {
    if (value is! List<Object?> || value.length > 1024) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime returned an invalid plugin cache usage list.',
      );
    }
    return List<PluginCacheUsage>.unmodifiable(
      value.map(_decodePluginCacheUsage),
    );
  }
}

/// Clears one plugin's Runtime-owned private cache.
@immutable
final class ClearPluginCacheInvocation
    extends PluginInvocation<PluginCacheClearResult> {
  const ClearPluginCacheInvocation({required this.pluginId});

  final String pluginId;

  @override
  String get _wireMethod => 'plugins.cache.clear.v1';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{
    'pluginId': pluginId,
  };

  @override
  PluginCacheClearResult _decodeResult(Object? value) =>
      _decodePluginCacheClearResult(value);
}

/// Clears every currently installed plugin cache in one Runtime-owned action.
@immutable
final class ClearAllPluginCachesInvocation
    extends PluginInvocation<PluginCacheClearResult> {
  const ClearAllPluginCachesInvocation();

  @override
  String get _wireMethod => 'plugins.cache.clearAll.v1';

  @override
  Map<String, Object?> get _wireParams => const <String, Object?>{};

  @override
  PluginCacheClearResult _decodeResult(Object? value) =>
      _decodePluginCacheClearResult(value);
}

PluginCacheUsage _decodePluginCacheUsage(Object? value) {
  final item = _jsonObject(value, 'Plugin cache usage');
  final pluginId = item['pluginId'];
  final bytes = item['bytes'];
  if (pluginId is! String || bytes is! int || bytes < 0) {
    throw const PluginRuntimeException(
      'invalid_response',
      'The Runtime returned an invalid plugin cache usage projection.',
    );
  }
  return PluginCacheUsage(pluginId: pluginId, bytes: bytes);
}

PluginCacheClearResult _decodePluginCacheClearResult(Object? value) {
  final result = _jsonObject(value, 'Plugin cache clear result');
  final items = result['items'];
  if (items is! List<Object?> || items.length > 1024) {
    throw const PluginRuntimeException(
      'invalid_response',
      'The Runtime returned an invalid plugin cache clear result.',
    );
  }
  return PluginCacheClearResult(
    items: List<PluginCacheClearItem>.unmodifiable(
      items.map(_decodePluginCacheClearItem),
    ),
  );
}

PluginCacheClearItem _decodePluginCacheClearItem(Object? value) {
  final item = _jsonObject(value, 'Plugin cache clear item');
  final pluginId = item['pluginId'];
  final bytesBefore = item['bytesBefore'];
  final bytesRemaining = item['bytesRemaining'];
  final status = item['status'];
  final parsedStatus = switch (status) {
    'cleared' => PluginCacheClearStatus.cleared,
    'failed' => PluginCacheClearStatus.failed,
    _ => null,
  };
  if (pluginId is! String ||
      bytesBefore is! int ||
      bytesBefore < 0 ||
      bytesRemaining is! int ||
      bytesRemaining < 0 ||
      parsedStatus == null) {
    throw const PluginRuntimeException(
      'invalid_response',
      'The Runtime returned an invalid plugin cache clear item.',
    );
  }
  return PluginCacheClearItem(
    pluginId: pluginId,
    bytesBefore: bytesBefore,
    bytesRemaining: bytesRemaining,
    status: parsedStatus,
  );
}

/// A path-free cache byte projection owned by the Runtime.
@immutable
final class PluginCacheUsage {
  const PluginCacheUsage({required this.pluginId, required this.bytes});

  final String pluginId;
  final int bytes;
}

enum PluginCacheClearStatus { cleared, failed }

/// Terminal statuses from a Runtime cache clear request.
@immutable
final class PluginCacheClearResult {
  const PluginCacheClearResult({required this.items});

  final List<PluginCacheClearItem> items;
}

/// The result for one plugin; private paths and raw errors are never returned.
@immutable
final class PluginCacheClearItem {
  const PluginCacheClearItem({
    required this.pluginId,
    required this.bytesBefore,
    required this.bytesRemaining,
    required this.status,
  });

  final String pluginId;
  final int bytesBefore;
  final int bytesRemaining;
  final PluginCacheClearStatus status;
}

InstalledPlugin _decodeInstalledPlugin(Object? value) {
  final item = _jsonObject(value, 'Installed plugin');
  final id = item['id'];
  final name = item['name'];
  final displayName = item['displayName'];
  final activeVersion = item['activeVersion'];
  final pendingVersion = item['pendingVersion'];
  final enabled = item['enabled'];
  final status = item['status'];
  final kinds = item['contentKinds'];
  if (id is! String ||
      name is! String ||
      displayName is! String ||
      (activeVersion != null && activeVersion is! String) ||
      (pendingVersion != null && pendingVersion is! String) ||
      enabled is! bool ||
      status is! String ||
      kinds is! List<Object?> ||
      kinds.any((Object? kind) => kind is! String)) {
    throw const PluginRuntimeException(
      'invalid_response',
      'The Runtime returned an invalid installed-plugin projection.',
    );
  }
  return InstalledPlugin(
    activeVersion: activeVersion as String?,
    contentKinds: List<String>.unmodifiable(kinds.cast<String>()),
    displayName: displayName,
    enabled: enabled,
    id: id,
    name: name,
    pendingVersion: pendingVersion as String?,
    status: status,
  );
}

/// Strong Flutter projection of one Runtime-owned plugin installation.
@immutable
final class InstalledPlugin {
  const InstalledPlugin({
    required this.activeVersion,
    required this.contentKinds,
    required this.displayName,
    required this.enabled,
    required this.id,
    required this.name,
    required this.pendingVersion,
    required this.status,
  });

  final String? activeVersion;
  final List<String> contentKinds;
  final String displayName;
  final bool enabled;
  final String id;
  final String name;
  final String? pendingVersion;
  final String status;
}
