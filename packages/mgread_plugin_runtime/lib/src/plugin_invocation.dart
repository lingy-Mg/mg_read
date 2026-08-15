part of mgread_plugin_runtime;

/// A versioned, typed Runtime capability call.
@immutable
sealed class PluginInvocation<T> {
  const PluginInvocation();

  String get _wireMethod;
  Map<String, Object?> get _wireParams;
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
        final item = _jsonObject(raw, 'Installed plugin');
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
      }),
    );
  }
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
