part of mgread_plugin_runtime;

const _maxDevelopmentPluginNameLength = 256;
const _maxDevelopmentBuildOutputLength = 64 * 1024;

/// Stable kinds emitted after a desktop development build settles.
enum DevelopmentPluginChangeKind { added, updated, removed, buildFailed, activationFailed }

@immutable
final class DevelopmentPluginChange {
  const DevelopmentPluginChange({required this.kind, required this.pluginId, this.pluginName, this.buildOutput});

  final DevelopmentPluginChangeKind kind;
  final String? pluginId;
  final String? pluginName;
  final String? buildOutput;

  bool get isFailure => kind == DevelopmentPluginChangeKind.buildFailed || kind == DevelopmentPluginChangeKind.activationFailed;
}

@immutable
final class DevelopmentPluginChangeBatch {
  DevelopmentPluginChangeBatch({required this.revision, required Iterable<DevelopmentPluginChange> changes})
    : changes = List<DevelopmentPluginChange>.unmodifiable(changes);

  final int revision;
  final List<DevelopmentPluginChange> changes;

  bool get hasFailure => changes.any((change) => change.isFailure);
}

DevelopmentPluginChangeBatch _decodeDevelopmentPluginChangeBatch(_RuntimeJsonObject envelope) {
  final revision = envelope['revision'];
  final rawChanges = envelope['changes'];
  if (revision is! int || revision <= 0 || rawChanges is! List<Object?> || rawChanges.isEmpty || rawChanges.length > 64) {
    throw const PluginRuntimeException('invalid_response', 'The Runtime returned an invalid development change event.');
  }
  final changes = rawChanges.map((raw) {
    final item = _jsonObject(raw, 'Development source change');
    final pluginId = item['pluginId'];
    if (pluginId != null && (pluginId is! String || !RegExp(r'^[a-z0-9]+(?:[.-][a-z0-9]+)+$').hasMatch(pluginId))) {
      throw const PluginRuntimeException('invalid_response', 'The Runtime returned an invalid development source identity.');
    }
    final pluginName = item['pluginName'];
    if (pluginName != null && (pluginName is! String || pluginName.isEmpty || pluginName.length > _maxDevelopmentPluginNameLength)) {
      throw const PluginRuntimeException('invalid_response', 'The Runtime returned an invalid development source name.');
    }
    final buildOutput = item['buildOutput'];
    if (buildOutput != null && (buildOutput is! String || buildOutput.length > _maxDevelopmentBuildOutputLength)) {
      throw const PluginRuntimeException('invalid_response', 'The Runtime returned oversized development build output.');
    }
    final kind = switch (item['kind']) {
      'added' => DevelopmentPluginChangeKind.added,
      'updated' => DevelopmentPluginChangeKind.updated,
      'removed' => DevelopmentPluginChangeKind.removed,
      'build_failed' => DevelopmentPluginChangeKind.buildFailed,
      'activation_failed' => DevelopmentPluginChangeKind.activationFailed,
      _ => null,
    };
    if (kind == null) {
      throw const PluginRuntimeException('invalid_response', 'The Runtime returned an unknown development change kind.');
    }
    return DevelopmentPluginChange(
      buildOutput: buildOutput as String?,
      kind: kind,
      pluginId: pluginId as String?,
      pluginName: pluginName as String?,
    );
  });
  return DevelopmentPluginChangeBatch(revision: revision, changes: changes);
}
