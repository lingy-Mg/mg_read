part of mgread_plugin_runtime;

const int maxPluginTransferBytes = 32 * 1024 * 1024;
const int maxPluginTransferBatch = 32;
const int maxPluginTransferBatchBytes = 512 * 1024 * 1024;

@immutable
final class PluginTransferArchive {
  const PluginTransferArchive({
    required this.bytes,
    required this.pluginId,
    required this.sha256,
    required this.version,
  });

  final int bytes;
  final String pluginId;
  final String sha256;
  final String version;

  Map<String, Object?> toJson() => <String, Object?>{
    'bytes': bytes,
    'id': pluginId,
    'sha256': sha256,
    'version': version,
  };
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
    extends PluginInvocation<List<PluginTransferArchive>> {
  const PluginTransferListInvocation();

  @override
  String get _wireMethod => 'plugins.transfer.list.v1';

  @override
  Map<String, Object?> get _wireParams => const <String, Object?>{};

  @override
  List<PluginTransferArchive> _decodeResult(Object? value) {
    if (value is! List<Object?> || value.length > 1024) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime returned an invalid plugin transfer list.',
      );
    }
    return List<PluginTransferArchive>.unmodifiable(
      value.map(_decodePluginTransferArchive),
    );
  }
}

@immutable
final class PluginTransferPlanInvocation
    extends PluginInvocation<List<PluginTransferPlanItem>> {
  PluginTransferPlanInvocation({required this.archives})
    : assert(archives.length <= maxPluginTransferBatch);

  final List<PluginTransferArchive> archives;

  @override
  String get _wireMethod => 'plugins.transfer.plan.v1';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{
    'archives': archives.map((archive) => archive.toJson()).toList(),
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

PluginTransferArchive _decodePluginTransferArchive(Object? value) {
  final item = _jsonObject(value, 'Plugin transfer archive');
  final bytes = item['bytes'];
  final pluginId = item['id'];
  final sha256 = item['sha256'];
  final version = item['version'];
  if (bytes is! int ||
      bytes <= 0 ||
      bytes > maxPluginTransferBytes ||
      pluginId is! String ||
      version is! String ||
      sha256 is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
    throw const PluginRuntimeException(
      'invalid_response',
      'The Runtime returned an invalid plugin transfer archive.',
    );
  }
  return PluginTransferArchive(
    bytes: bytes,
    pluginId: pluginId,
    sha256: sha256,
    version: version,
  );
}
