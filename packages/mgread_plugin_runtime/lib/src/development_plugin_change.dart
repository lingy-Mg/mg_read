part of mgread_plugin_runtime;

/// Stable kinds emitted after a Windows desktop development build settles.
enum DevelopmentPluginChangeKind {
  added,
  updated,
  removed,
  buildFailed,
  activationFailed,
}

@immutable
final class DevelopmentPluginChange {
  const DevelopmentPluginChange({required this.kind, required this.pluginId});

  final DevelopmentPluginChangeKind kind;
  final String? pluginId;

  bool get isFailure =>
      kind == DevelopmentPluginChangeKind.buildFailed ||
      kind == DevelopmentPluginChangeKind.activationFailed;
}

@immutable
final class DevelopmentPluginChangeBatch {
  DevelopmentPluginChangeBatch({
    required this.revision,
    required Iterable<DevelopmentPluginChange> changes,
  }) : changes = List<DevelopmentPluginChange>.unmodifiable(changes);

  final int revision;
  final List<DevelopmentPluginChange> changes;

  bool get hasFailure => changes.any((change) => change.isFailure);
}

DevelopmentPluginChangeBatch _decodeDevelopmentPluginChangeBatch(
  _RuntimeJsonObject envelope,
) {
  final revision = envelope['revision'];
  final rawChanges = envelope['changes'];
  if (revision is! int ||
      revision <= 0 ||
      rawChanges is! List<Object?> ||
      rawChanges.isEmpty ||
      rawChanges.length > 64) {
    throw const PluginRuntimeException(
      'invalid_response',
      'The Runtime returned an invalid development change event.',
    );
  }
  final changes = rawChanges.map((raw) {
    final item = _jsonObject(raw, 'Development source change');
    final pluginId = item['pluginId'];
    if (pluginId != null &&
        (pluginId is! String ||
            !RegExp(r'^[a-z0-9]+(?:[.-][a-z0-9]+)+$').hasMatch(pluginId))) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime returned an invalid development source identity.',
      );
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
      throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime returned an unknown development change kind.',
      );
    }
    return DevelopmentPluginChange(kind: kind, pluginId: pluginId as String?);
  });
  return DevelopmentPluginChangeBatch(revision: revision, changes: changes);
}
