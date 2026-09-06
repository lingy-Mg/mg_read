part of mgread_plugin_runtime;

const int maxPluginTransferBytes = 32 * 1024 * 1024;
const int maxPluginTransferBatch = 32;
const int maxPluginTransferBatchBytes = 512 * 1024 * 1024;

enum PluginArtifactFormat { singleFile, archive }

enum PluginArtifactProvenance { installed, development, developmentReplica }

@immutable
final class PluginTransferArtifact {
  const PluginTransferArtifact({
    required this.bytes,
    required this.developmentFingerprint,
    required this.developmentRevision,
    required this.format,
    required this.pluginId,
    required this.provenance,
    required this.sha256,
    required this.version,
  });

  final int bytes;
  final String? developmentFingerprint;
  final int? developmentRevision;
  final PluginArtifactFormat format;
  final String pluginId;
  final PluginArtifactProvenance provenance;
  final String sha256;
  final String version;

  Map<String, Object?> toJson() => <String, Object?>{
    'bytes': bytes,
    'developmentFingerprint': developmentFingerprint,
    'developmentRevision': developmentRevision,
    'format': format.name,
    'id': pluginId,
    'provenance': provenance.name,
    'sha256': sha256,
    'version': version,
  };
}

/// Transferable version metadata that does not materialize development bytes.
@immutable
final class PluginTransferOffer {
  const PluginTransferOffer({
    required this.developmentFingerprint,
    required this.developmentRevision,
    required this.format,
    required this.pluginId,
    required this.provenance,
    required this.version,
  });

  final String? developmentFingerprint;
  final int? developmentRevision;
  final PluginArtifactFormat format;
  final String pluginId;
  final PluginArtifactProvenance provenance;
  final String version;

  Map<String, Object?> toJson() => <String, Object?>{
    'developmentFingerprint': developmentFingerprint,
    'developmentRevision': developmentRevision,
    'format': format.name,
    'id': pluginId,
    'provenance': provenance.name,
    'version': version,
  };
}

@immutable
final class MaterializedPluginArtifact {
  const MaterializedPluginArtifact({
    required this.artifact,
    required this.bytes,
  });

  final PluginTransferArtifact artifact;
  final Stream<List<int>> bytes;
}

/// Safe result of exporting one Windows desktop development source to a user-selected directory.
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
  developmentConflict,
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

  // Listing exportable artifacts packages every Windows desktop development
  // source before returning. Keep it on the same bounded transfer window as
  // the other artifact operations instead of the five-second control window.
  @override
  Duration get _timeout => const Duration(minutes: 2);

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
final class PluginTransferOfferListInvocation
    extends PluginInvocation<List<PluginTransferOffer>> {
  const PluginTransferOfferListInvocation();

  @override
  String get _wireMethod => 'plugins.transfer.offers.v1';

  // Offer listing may initialize and load all development plugins before
  // returning. Keep this metadata-only call bounded, but allow cold Runtime
  // startup and development-plugin loading more time than the 5-second
  // control timeout.
  @override
  Duration get _timeout => const Duration(seconds: 30);

  @override
  Map<String, Object?> get _wireParams => const <String, Object?>{};

  @override
  List<PluginTransferOffer> _decodeResult(Object? value) {
    if (value is! List<Object?> || value.length > maxPluginTransferBatch) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime returned an invalid plugin transfer offer list.',
      );
    }
    return List<PluginTransferOffer>.unmodifiable(
      value.map(_decodePluginTransferOffer),
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
  List<PluginTransferPlanItem> _decodeResult(Object? value) =>
      _decodePluginTransferPlan(value);
}

@immutable
final class PluginTransferOfferPlanInvocation
    extends PluginInvocation<List<PluginTransferPlanItem>> {
  PluginTransferOfferPlanInvocation({required this.offers})
    : assert(offers.length <= maxPluginTransferBatch);

  final List<PluginTransferOffer> offers;

  @override
  String get _wireMethod => 'plugins.transfer.offers.plan.v1';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{
    'offers': offers.map((offer) => offer.toJson()).toList(),
  };

  @override
  List<PluginTransferPlanItem> _decodeResult(Object? value) =>
      _decodePluginTransferPlan(value);
}

PluginTransferArtifact _decodePluginTransferArtifact(Object? value) {
  final item = _jsonObject(value, 'Plugin transfer artifact');
  final bytes = item['bytes'];
  final developmentFingerprint = item['developmentFingerprint'];
  final developmentRevision = item['developmentRevision'];
  final format = switch (item['format']) {
    'singleFile' => PluginArtifactFormat.singleFile,
    'archive' => PluginArtifactFormat.archive,
    _ => null,
  };
  final pluginId = item['id'];
  final provenance = switch (item['provenance']) {
    'installed' => PluginArtifactProvenance.installed,
    'development' => PluginArtifactProvenance.development,
    'developmentReplica' => PluginArtifactProvenance.developmentReplica,
    _ => null,
  };
  final sha256 = item['sha256'];
  final version = item['version'];
  if (bytes is! int ||
      bytes <= 0 ||
      bytes > maxPluginTransferBytes ||
      format == null ||
      pluginId is! String ||
      provenance == null ||
      version is! String ||
      sha256 is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
      (provenance == PluginArtifactProvenance.installed &&
          (developmentFingerprint != null || developmentRevision != null)) ||
      (provenance != PluginArtifactProvenance.installed &&
          (developmentFingerprint is! String ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(developmentFingerprint) ||
              developmentRevision is! int ||
              developmentRevision <= 0))) {
    throw const PluginRuntimeException(
      'invalid_response',
      'The Runtime returned an invalid plugin transfer artifact.',
    );
  }
  return PluginTransferArtifact(
    bytes: bytes,
    developmentFingerprint: developmentFingerprint as String?,
    developmentRevision: developmentRevision as int?,
    format: format,
    pluginId: pluginId,
    provenance: provenance,
    sha256: sha256,
    version: version,
  );
}

PluginTransferOffer _decodePluginTransferOffer(Object? value) {
  final item = _jsonObject(value, 'Plugin transfer offer');
  final developmentFingerprint = item['developmentFingerprint'];
  final developmentRevision = item['developmentRevision'];
  final format = switch (item['format']) {
    'singleFile' => PluginArtifactFormat.singleFile,
    'archive' => PluginArtifactFormat.archive,
    _ => null,
  };
  final pluginId = item['id'];
  final provenance = switch (item['provenance']) {
    'installed' => PluginArtifactProvenance.installed,
    'development' => PluginArtifactProvenance.development,
    'developmentReplica' => PluginArtifactProvenance.developmentReplica,
    _ => null,
  };
  final version = item['version'];
  if (format == null ||
      pluginId is! String ||
      provenance == null ||
      version is! String ||
      (provenance == PluginArtifactProvenance.installed &&
          (developmentFingerprint != null || developmentRevision != null)) ||
      (provenance != PluginArtifactProvenance.installed &&
          (developmentFingerprint is! String ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(developmentFingerprint) ||
              developmentRevision is! int ||
              developmentRevision <= 0))) {
    throw const PluginRuntimeException(
      'invalid_response',
      'The Runtime returned an invalid plugin transfer offer.',
    );
  }
  return PluginTransferOffer(
    developmentFingerprint: developmentFingerprint as String?,
    developmentRevision: developmentRevision as int?,
    format: format,
    pluginId: pluginId,
    provenance: provenance,
    version: version,
  );
}

List<PluginTransferPlanItem> _decodePluginTransferPlan(Object? value) {
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
        'developmentConflict' => PluginTransferPlanAction.developmentConflict,
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
