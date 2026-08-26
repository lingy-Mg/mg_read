part of mgread_plugin_runtime;

const int maxPluginTransferBytes = 32 * 1024 * 1024;
const int maxPluginTransferBatch = 32;
const int maxPluginTransferBatchBytes = 512 * 1024 * 1024;

enum PluginArtifactFormat { singleFile, archive }

@immutable
final class PluginTransferArtifact {
  const PluginTransferArtifact({
    required this.bytes,
    required this.format,
    required this.pluginId,
    required this.sha256,
    required this.version,
  });

  final int bytes;
  final PluginArtifactFormat format;
  final String pluginId;
  final String sha256;
  final String version;

  Map<String, Object?> toJson() => <String, Object?>{
    'bytes': bytes,
    'format': format.name,
    'id': pluginId,
    'sha256': sha256,
    'version': version,
  };
}

/// Safe result of exporting one Windows Debug development source to a user-selected directory.
@immutable
final class PluginDevelopmentPackage {
  const PluginDevelopmentPackage({
    required this.artifact,
    required this.fileName,
  });

  final PluginTransferArtifact artifact;
  final String fileName;
}

enum PluginTransferPlanAction {
  missing,
  upgrade,
  same,
  receiverNewer,
  unavailable,
}

@immutable
final class PluginTransferPlanItem {
  const PluginTransferPlanItem({
    required this.action,
    required this.pluginId,
    required this.receiverVersion,
    required this.version,
  });

  final PluginTransferPlanAction action;
  final String pluginId;
  final String? receiverVersion;
  final String version;
}

enum PluginTransferImportStatus { installed, failed }

@immutable
final class PluginTransferImportResult {
  const PluginTransferImportResult({
    required this.pluginId,
    required this.status,
    required this.version,
  });

  final String pluginId;
  final PluginTransferImportStatus status;
  final String version;
}

@immutable
final class PluginTransferListInvocation
    extends PluginInvocation<List<PluginTransferArtifact>> {
  const PluginTransferListInvocation();

  @override
  String get _wireMethod => 'plugins.transfer.list.v2';

  @override
  Map<String, Object?> get _wireParams => const <String, Object?>{};

  @override
  List<PluginTransferArtifact> _decodeResult(Object? value) {
    if (value is! List<Object?> || value.length > 1024) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime returned an invalid plugin transfer list.',
      );
    }
    return List<PluginTransferArtifact>.unmodifiable(
      value.map(_decodePluginTransferArtifact),
    );
  }
}

@immutable
final class PluginTransferPlanInvocation
    extends PluginInvocation<List<PluginTransferPlanItem>> {
  PluginTransferPlanInvocation({required this.artifacts})
    : assert(artifacts.length <= maxPluginTransferBatch);

  final List<PluginTransferArtifact> artifacts;

  @override
  String get _wireMethod => 'plugins.transfer.plan.v2';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{
    'artifacts': artifacts.map((artifact) => artifact.toJson()).toList(),
  };

  @override
  List<PluginTransferPlanItem> _decodeResult(Object? value) {
    if (value is! List<Object?> || value.length > maxPluginTransferBatch) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime returned an invalid plugin transfer plan.',
      );
    }
    return List<PluginTransferPlanItem>.unmodifiable(
      value.map((raw) {
        final item = _jsonObject(raw, 'Plugin transfer plan item');
        final action = switch (item['action']) {
          'missing' => PluginTransferPlanAction.missing,
          'upgrade' => PluginTransferPlanAction.upgrade,
          'same' => PluginTransferPlanAction.same,
          'receiverNewer' => PluginTransferPlanAction.receiverNewer,
          'unavailable' => PluginTransferPlanAction.unavailable,
          _ => throw const PluginRuntimeException(
            'invalid_response',
            'The Runtime returned an invalid plugin transfer action.',
          ),
        };
        final pluginId = item['id'];
        final version = item['version'];
        final receiverVersion = item['receiverVersion'];
        if (pluginId is! String ||
            version is! String ||
            (receiverVersion != null && receiverVersion is! String)) {
          throw const PluginRuntimeException(
            'invalid_response',
            'The Runtime returned an invalid plugin transfer plan item.',
          );
        }
        return PluginTransferPlanItem(
          action: action,
          pluginId: pluginId,
          receiverVersion: receiverVersion as String?,
          version: version,
        );
      }),
    );
  }
}

PluginTransferArtifact _decodePluginTransferArtifact(Object? value) {
  final item = _jsonObject(value, 'Plugin transfer artifact');
  final bytes = item['bytes'];
  final format = switch (item['format']) {
    'singleFile' => PluginArtifactFormat.singleFile,
    'archive' => PluginArtifactFormat.archive,
    _ => null,
  };
  final pluginId = item['id'];
  final sha256 = item['sha256'];
  final version = item['version'];
  if (bytes is! int ||
      bytes <= 0 ||
      bytes > maxPluginTransferBytes ||
      format == null ||
      pluginId is! String ||
      version is! String ||
      sha256 is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
    throw const PluginRuntimeException(
      'invalid_response',
      'The Runtime returned an invalid plugin transfer artifact.',
    );
  }
  return PluginTransferArtifact(
    bytes: bytes,
    format: format,
    pluginId: pluginId,
    sha256: sha256,
    version: version,
  );
}
