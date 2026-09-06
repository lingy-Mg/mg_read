/// MgRead 局域网同步应用网关。
///
/// 职责：
/// - 组合应用书架快照与 Runtime path-free artifact Facade。
/// - 编排插件计划、原样流式导入和书架事务应用。
///
/// 注意：
/// - 不读取 Runtime 数据根，也不转换 single-file 与 archive 格式。
/// - 批量导入流在完成、失败或取消时必须关闭。
/// - 取消和资源清理失败不得泄漏到应用级未处理异常边界。
///
library;

import 'dart:async';

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

/// Bridges the app-owned library and the path-free Runtime transfer facade.
final class MgReadLanSyncGateway implements LanSyncGateway, LanSyncPairedGateway {
  MgReadLanSyncGateway(this._library, this._runtime);

  final ContentLibrary _library;
  final PluginRuntime _runtime;

  LanSyncManifest? _pendingManifest;
  LibrarySyncSnapshot? _pendingSnapshot;
  LibrarySyncPreview? _pendingPreview;
  int _installed = 0;
  int _skipped = 0;
  int _failed = 0;
  int _preparedCount = 0;
  final Map<String, StreamController<List<int>>> _importControllers = <String, StreamController<List<int>>>{};
  Future<List<PluginTransferImportResult>>? _batchImport;
  String? _batchFailureCode;

  @override
  Future<LanSyncManifest> createManifest() => createPairedManifest();

  @override
  Future<LanSyncManifest> createPairedManifest({
    bool includePlugins = true,
    bool includeShelf = true,
    bool deferPluginArtifacts = false,
  }) async {
    final snapshot = includeShelf
        ? await _library.createSyncSnapshot()
        : const LibrarySyncSnapshot(items: <LibrarySyncItem>[], skippedSourceLessItems: 0);
    final shelf = _projectShelfItems(snapshot);
    if (!includePlugins) {
      return _validatedManifest(plugins: const <LanSyncPluginDescriptor>[], shelfItems: shelf.items, skippedShelfItems: shelf.skipped);
    }
    final installed = await _runtime.invoke(const InstalledPluginsInvocation());
    final artifacts = deferPluginArtifacts ? const <PluginTransferArtifact>[] : await _runtime.invoke(const PluginTransferListInvocation());
    final offers = deferPluginArtifacts ? await _runtime.invoke(const PluginTransferOfferListInvocation()) : const <PluginTransferOffer>[];
    final installedById = <String, InstalledPlugin>{for (final plugin in installed) plugin.id: plugin};
    final artifactsById = <String, PluginTransferArtifact>{for (final artifact in artifacts) artifact.pluginId: artifact};
    final offersById = <String, PluginTransferOffer>{for (final offer in offers) offer.pluginId: offer};
    final requestedVersions = <String, String>{
      for (final item in shelf.items) item.pluginId: item.pluginVersion,
      for (final plugin in installed)
        if (plugin.activeVersion != null)
          plugin.id: plugin.status == 'development'
              ? artifactsById[plugin.id]?.version ?? offersById[plugin.id]?.version ?? plugin.activeVersion!
              : plugin.activeVersion!,
    };
    if (requestedVersions.length > lanSyncMaxPluginCount) {
      throw StateError('lan_sync_plugin_count_exceeded');
    }
    final plugins = <LanSyncPluginDescriptor>[];
    for (final entry in requestedVersions.entries) {
      final artifact = _findArtifact(artifacts, entry.key, entry.value);
      final offer = _findOffer(offers, entry.key, entry.value);
      final installedPlugin = installedById[entry.key];
      plugins.add(
        LanSyncPluginDescriptor(
          id: entry.key,
          version: entry.value,
          bytes: artifact?.bytes ?? 0,
          artifactFormat: _toLanArtifactFormat(artifact?.format ?? offer?.format ?? PluginArtifactFormat.archive),
          developmentFingerprint: artifact?.developmentFingerprint ?? offer?.developmentFingerprint,
          developmentRevision: artifact?.developmentRevision ?? offer?.developmentRevision,
          sha256: artifact?.sha256 ?? ''.padLeft(64, '0'),
          transferable: artifact != null || offer != null,
          deferred: offer != null,
          displayName: installedPlugin?.displayName,
          provenance: _toLanProvenance(artifact?.provenance ?? offer?.provenance ?? PluginArtifactProvenance.installed),
          reason: artifact == null && offer == null ? 'artifact_unavailable' : null,
        ),
      );
    }
    return _validatedManifest(
      plugins: List<LanSyncPluginDescriptor>.unmodifiable(plugins),
      shelfItems: shelf.items,
      skippedShelfItems: shelf.skipped,
    );
  }

  @override
  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin) {
    if (!plugin.transferable || plugin.deferred) {
      throw StateError('lan_sync_plugin_archive_unavailable');
    }
    return _runtime.exportPluginArtifact(_toRuntimeArtifact(plugin));
  }

  @override
  Future<LanSyncMaterializedPlugin> materializePluginArchive(LanSyncPluginDescriptor plugin) async {
    if (!plugin.transferable) {
      throw StateError('lan_sync_plugin_archive_unavailable');
    }
    if (!plugin.deferred) {
      return LanSyncMaterializedPlugin(descriptor: plugin, bytes: await openPluginArchive(plugin));
    }
    final MaterializedPluginArtifact materialized;
    try {
      materialized = await _runtime.materializePluginArtifact(_toRuntimeOffer(plugin));
    } on PluginRuntimeException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        LanSyncGatewayException(_runtimeFailureCode(error), reason: 'runtimeCode=${error.code} ${error.message}'),
        stackTrace,
      );
    }
    return LanSyncMaterializedPlugin(
      descriptor: LanSyncPluginDescriptor(
        id: plugin.id,
        version: plugin.version,
        bytes: materialized.artifact.bytes,
        artifactFormat: _toLanArtifactFormat(materialized.artifact.format),
        developmentFingerprint: materialized.artifact.developmentFingerprint,
        developmentRevision: materialized.artifact.developmentRevision,
        sha256: materialized.artifact.sha256,
        transferable: true,
        displayName: plugin.displayName,
        provenance: _toLanProvenance(materialized.artifact.provenance),
      ),
      bytes: materialized.bytes,
    );
  }

  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest) async {
    _installed = 0;
    _skipped = 0;
    _failed = 0;
    final installed = await _runtime.invoke(const InstalledPluginsInvocation());
    final installedIds = installed.map((plugin) => plugin.id).toSet();
    final installedById = <String, InstalledPlugin>{for (final plugin in installed) plugin.id: plugin};
    final developmentIds = <String>{
      for (final plugin in installed)
        if (plugin.status == 'development') plugin.id,
    };
    final transferable = manifest.plugins
        .where((plugin) => plugin.transferable && !plugin.deferred)
        .map(_toRuntimeArtifact)
        .toList(growable: false);
    final deferred = manifest.plugins
        .where((plugin) => plugin.transferable && plugin.deferred)
        .map(_toRuntimeOffer)
        .toList(growable: false);
    final artifactPlans = transferable.isEmpty
        ? const <PluginTransferPlanItem>[]
        : await _runtime.invoke(PluginTransferPlanInvocation(artifacts: transferable));
    final offerPlans = deferred.isEmpty
        ? const <PluginTransferPlanItem>[]
        : await _runtime.invoke(PluginTransferOfferPlanInvocation(offers: deferred));
    final plans = <PluginTransferPlanItem>[...artifactPlans, ...offerPlans];
    final planById = <String, PluginTransferPlanItem>{for (final plan in plans) plan.pluginId: plan};
    final featurePlans = <String, LanSyncPluginPlanState>{};
    final availableAfterTransfer = <String>{...installedIds};
    for (final plugin in manifest.plugins) {
      final plan = planById[plugin.id];
      final state = developmentIds.contains(plugin.id)
          ? plan?.action == PluginTransferPlanAction.same
                ? LanSyncPluginPlanState.sameVersion
                : LanSyncPluginPlanState.developmentConflict
          : plan == null
          ? _planUnavailableArchive(plugin, installedById[plugin.id])
          : _toFeaturePlan(plan.action);
      featurePlans[plugin.id] = state;
      if (state == LanSyncPluginPlanState.missing || state == LanSyncPluginPlanState.upgrade) {
        availableAfterTransfer.add(plugin.id);
      }
      if (state == LanSyncPluginPlanState.sameVersion || state == LanSyncPluginPlanState.receiverNewer) {
        _skipped++;
      }
    }
    final snapshot = _toLibrarySnapshot(manifest);
    final preview = await _library.previewSyncSnapshot(snapshot, availablePluginIds: availableAfterTransfer);
    _pendingManifest = manifest;
    _pendingSnapshot = snapshot;
    _pendingPreview = preview;
    return LanSyncImportPreview(
      newItemCount: preview.newItems.length,
      conflicts: List<LanSyncBookConflict>.unmodifiable(
        preview.conflicts.map(
          (conflict) => LanSyncBookConflict(
            identity: _identityText(conflict.identity),
            senderTitle: conflict.sender.title,
            localTitle: conflict.local.title,
          ),
        ),
      ),
      blockedItemCount: preview.blocked.length,
      pluginPlans: Map<String, LanSyncPluginPlanState>.unmodifiable(featurePlans),
      selectedPluginIds: <String>{
        for (final entry in featurePlans.entries)
          if (entry.value == LanSyncPluginPlanState.missing || entry.value == LanSyncPluginPlanState.upgrade) entry.key,
      },
      selectedShelfItemIds: <String>{for (final item in manifest.shelfItems) item.identity},
    );
  }

  @override
  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins) async {
    await cancelPluginImports();
    _preparedCount = plugins.length;
    _batchFailureCode = null;
    if (plugins.isEmpty) return;
    final installed = await _runtime.invoke(const InstalledPluginsInvocation());
    final developmentIds = <String>{
      for (final plugin in installed)
        if (plugin.status == 'development') plugin.id,
    };
    for (final plugin in plugins) {
      if (developmentIds.contains(plugin.id)) {
        throw StateError('lan_sync_plugin_development_priority');
      }
      if (!plugin.transferable || plugin.deferred || _importControllers.containsKey(plugin.id)) {
        throw StateError('lan_sync_plugin_selection_invalid');
      }
      _importControllers[plugin.id] = StreamController<List<int>>();
    }
    final batch = _runtime.importPluginArtifacts(<({PluginTransferArtifact artifact, Stream<List<int>> bytes})>[
      for (final plugin in plugins) (artifact: _toRuntimeArtifact(plugin), bytes: _importControllers[plugin.id]!.stream),
    ]);
    _batchImport = batch;
    // The Runtime validates the batch before the peer starts sending bytes. A
    // failure can therefore arrive before finishPluginImports awaits it. Keep a
    // permanent observer attached so this expected failure stays in the sync
    // transaction instead of reaching the process-level error boundary.
    unawaited(_observeBatchImport(batch));
  }

  @override
  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) async {
    final controller = _importControllers.remove(plugin.id);
    if (controller == null) {
      throw StateError('lan_sync_plugin_not_prepared');
    }
    await controller.addStream(bytes);
    await controller.close();
  }

  @override
  Future<LanSyncPluginImportResult> finishPluginImports() async {
    if (_importControllers.isNotEmpty) {
      await cancelPluginImports();
      throw StateError('lan_sync_plugin_batch_incomplete');
    }
    final batch = _batchImport;
    _batchImport = null;
    if (batch != null) {
      try {
        final results = await batch;
        _installed += results.where((result) => result.status == PluginTransferImportStatus.installed).length;
        _failed += results.where((result) => result.status == PluginTransferImportStatus.failed).length;
      } on Object catch (error) {
        _failed += _preparedCount;
        _batchFailureCode ??= _runtimeFailureCode(error);
      }
    }
    _preparedCount = 0;
    final installed = await _runtime.invoke(const InstalledPluginsInvocation());
    return LanSyncPluginImportResult(
      availablePluginIds: Set<String>.unmodifiable(installed.map((plugin) => plugin.id)),
      installed: _installed,
      skipped: _skipped,
      failed: _failed,
      failureCode: _batchFailureCode,
    );
  }

  @override
  Future<void> cancelPluginImports() async {
    final controllers = _importControllers.values.toList(growable: false);
    _importControllers.clear();
    for (final controller in controllers) {
      if (!controller.isClosed) {
        try {
          await controller.close();
        } on Object {
          // 取消阶段继续清理其他插件流。
        }
      }
    }
    final batch = _batchImport;
    _batchImport = null;
    _preparedCount = 0;
    if (batch != null) {
      try {
        await batch;
      } on Object {
        // Closed staged streams leave the previous Runtime installation live.
      }
    }
    _batchFailureCode = null;
  }

  Future<void> _observeBatchImport(Future<List<PluginTransferImportResult>> batch) async {
    try {
      await batch;
    } on Object catch (error) {
      _batchFailureCode ??= _runtimeFailureCode(error);
    }
  }

  @override
  Future<LanSyncApplyResult> applyImport({
    required LanSyncManifest manifest,
    required Map<String, LanSyncConflictChoice> conflictChoices,
    required Set<String> availablePluginIds,
    required LanSyncPluginImportResult pluginResult,
  }) async {
    var snapshot = _pendingSnapshot;
    var preview = _pendingPreview;
    if (!identical(_pendingManifest, manifest) || snapshot == null || preview == null) {
      snapshot = _toLibrarySnapshot(manifest);
      preview = await _library.previewSyncSnapshot(snapshot, availablePluginIds: availablePluginIds);
    } else if (pluginResult.failed > 0) {
      preview = await _library.previewSyncSnapshot(snapshot, availablePluginIds: availablePluginIds);
    }
    final choices = <LibrarySyncIdentity, LibrarySyncConflictChoice>{};
    var keptLocal = 0;
    for (final conflict in preview.conflicts) {
      final choice = conflictChoices[_identityText(conflict.identity)] ?? LanSyncConflictChoice.smartMerge;
      choices[conflict.identity] = _toLibraryChoice(choice);
      if (choice == LanSyncConflictChoice.keepLocal) keptLocal++;
    }
    final LibrarySyncApplyResult result;
    try {
      result = await _library.applySyncSnapshot(snapshot, preview: preview, choices: choices);
    } on BookshelfCapacityExceededException {
      throw const LanSyncGatewayException(bookshelfCapacityExceededCode);
    }
    if (result.code != LibrarySyncResultCode.applied) {
      throw StateError('lan_sync_library_${result.code.name}');
    }
    _pendingManifest = null;
    _pendingSnapshot = null;
    _pendingPreview = null;
    return LanSyncApplyResult(
      added: result.addedItems,
      updated: result.updatedItems,
      keptLocal: keptLocal,
      blocked: result.blockedItems,
      pluginInstalled: pluginResult.installed,
      pluginSkipped: pluginResult.skipped,
      pluginFailed: pluginResult.failed,
    );
  }
}

PluginTransferArtifact? _findArtifact(List<PluginTransferArtifact> artifacts, String pluginId, String version) {
  for (final artifact in artifacts) {
    if (artifact.pluginId == pluginId && artifact.version == version) {
      return artifact;
    }
  }
  return null;
}

PluginTransferOffer? _findOffer(List<PluginTransferOffer> offers, String pluginId, String version) {
  for (final offer in offers) {
    if (offer.pluginId == pluginId && offer.version == version) return offer;
  }
  return null;
}

PluginTransferArtifact _toRuntimeArtifact(LanSyncPluginDescriptor plugin) => PluginTransferArtifact(
  bytes: plugin.bytes,
  developmentFingerprint: plugin.developmentFingerprint,
  developmentRevision: plugin.developmentRevision,
  format: switch (plugin.artifactFormat) {
    LanSyncPluginArtifactFormat.singleFile => PluginArtifactFormat.singleFile,
    LanSyncPluginArtifactFormat.archive => PluginArtifactFormat.archive,
  },
  pluginId: plugin.id,
  provenance: _toRuntimeProvenance(plugin.provenance),
  sha256: plugin.sha256,
  version: plugin.version,
);

PluginTransferOffer _toRuntimeOffer(LanSyncPluginDescriptor plugin) => PluginTransferOffer(
  developmentFingerprint: plugin.developmentFingerprint,
  developmentRevision: plugin.developmentRevision,
  format: switch (plugin.artifactFormat) {
    LanSyncPluginArtifactFormat.singleFile => PluginArtifactFormat.singleFile,
    LanSyncPluginArtifactFormat.archive => PluginArtifactFormat.archive,
  },
  pluginId: plugin.id,
  provenance: _toRuntimeProvenance(plugin.provenance),
  version: plugin.version,
);

LanSyncPluginArtifactFormat _toLanArtifactFormat(PluginArtifactFormat format) => switch (format) {
  PluginArtifactFormat.singleFile => LanSyncPluginArtifactFormat.singleFile,
  PluginArtifactFormat.archive => LanSyncPluginArtifactFormat.archive,
};

LanSyncPluginProvenance _toLanProvenance(PluginArtifactProvenance provenance) => switch (provenance) {
  PluginArtifactProvenance.installed => LanSyncPluginProvenance.installed,
  PluginArtifactProvenance.development => LanSyncPluginProvenance.development,
  PluginArtifactProvenance.developmentReplica => LanSyncPluginProvenance.developmentReplica,
};

PluginArtifactProvenance _toRuntimeProvenance(LanSyncPluginProvenance provenance) => switch (provenance) {
  LanSyncPluginProvenance.installed => PluginArtifactProvenance.installed,
  LanSyncPluginProvenance.development => PluginArtifactProvenance.development,
  LanSyncPluginProvenance.developmentReplica => PluginArtifactProvenance.developmentReplica,
};

LanSyncPluginPlanState _toFeaturePlan(PluginTransferPlanAction action) => switch (action) {
  PluginTransferPlanAction.developmentConflict => LanSyncPluginPlanState.developmentConflict,
  PluginTransferPlanAction.missing => LanSyncPluginPlanState.missing,
  PluginTransferPlanAction.upgrade => LanSyncPluginPlanState.upgrade,
  PluginTransferPlanAction.same => LanSyncPluginPlanState.sameVersion,
  PluginTransferPlanAction.receiverNewer => LanSyncPluginPlanState.receiverNewer,
  PluginTransferPlanAction.unavailable => LanSyncPluginPlanState.unavailable,
};

LanSyncPluginPlanState _planUnavailableArchive(LanSyncPluginDescriptor sender, InstalledPlugin? receiver) {
  final receiverVersion = receiver?.activeVersion ?? receiver?.pendingVersion;
  if (receiverVersion == null) return LanSyncPluginPlanState.unavailable;
  final comparison = _compareSemver(receiverVersion, sender.version);
  if (comparison == 0) return LanSyncPluginPlanState.sameVersion;
  if (comparison > 0) return LanSyncPluginPlanState.receiverNewer;
  return LanSyncPluginPlanState.unavailable;
}

int _compareSemver(String left, String right) {
  final pattern = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$');
  final leftMatch = pattern.firstMatch(left);
  final rightMatch = pattern.firstMatch(right);
  if (leftMatch == null || rightMatch == null) return -1;
  final leftParts = <int>[int.parse(leftMatch.group(1)!), int.parse(leftMatch.group(2)!), int.parse(leftMatch.group(3)!)];
  final rightParts = <int>[int.parse(rightMatch.group(1)!), int.parse(rightMatch.group(2)!), int.parse(rightMatch.group(3)!)];
  for (var index = 0; index < leftParts.length; index++) {
    if (leftParts[index] != rightParts[index]) {
      return leftParts[index].compareTo(rightParts[index]);
    }
  }
  final leftPrerelease = leftMatch.group(4);
  final rightPrerelease = rightMatch.group(4);
  if (leftPrerelease == null && rightPrerelease == null) return 0;
  if (leftPrerelease == null) return 1;
  if (rightPrerelease == null) return -1;
  final leftIdentifiers = leftPrerelease.split('.');
  final rightIdentifiers = rightPrerelease.split('.');
  final sharedLength = leftIdentifiers.length < rightIdentifiers.length ? leftIdentifiers.length : rightIdentifiers.length;
  for (var index = 0; index < sharedLength; index++) {
    final leftNumber = int.tryParse(leftIdentifiers[index]);
    final rightNumber = int.tryParse(rightIdentifiers[index]);
    if (leftNumber != null && rightNumber != null && leftNumber != rightNumber) {
      return leftNumber.compareTo(rightNumber);
    }
    if (leftNumber != null && rightNumber == null) return -1;
    if (leftNumber == null && rightNumber != null) return 1;
    final textComparison = leftIdentifiers[index].compareTo(rightIdentifiers[index]);
    if (textComparison != 0) return textComparison;
  }
  return leftIdentifiers.length.compareTo(rightIdentifiers.length);
}

final class _LanSyncShelfProjection {
  const _LanSyncShelfProjection({required this.items, required this.skipped});

  final List<LanSyncShelfItem> items;
  final int skipped;
}

_LanSyncShelfProjection _projectShelfItems(LibrarySyncSnapshot snapshot) {
  final items = <LanSyncShelfItem>[];
  var skipped = snapshot.skippedSourceLessItems;
  for (final item in snapshot.items) {
    final projected = _toLanShelfItem(item);
    if (_isValidShelfItem(projected)) {
      items.add(projected);
      continue;
    }
    final withoutProgress = projected.progress == null ? null : _withoutProgress(projected);
    if (withoutProgress != null && _isValidShelfItem(withoutProgress)) {
      items.add(withoutProgress);
      continue;
    }
    skipped++;
  }
  return _LanSyncShelfProjection(items: List<LanSyncShelfItem>.unmodifiable(items), skipped: skipped);
}

bool _isValidShelfItem(LanSyncShelfItem item) {
  try {
    LanSyncShelfItem.fromJson(item.toJson());
    return true;
  } on FormatException {
    return false;
  }
}

LanSyncShelfItem _withoutProgress(LanSyncShelfItem item) => LanSyncShelfItem(
  pluginId: item.pluginId,
  pluginVersion: item.pluginVersion,
  remoteContentId: item.remoteContentId,
  contentKind: item.contentKind,
  title: item.title,
  author: item.author,
  coverUrl: item.coverUrl,
  sourceName: item.sourceName,
);

LanSyncManifest _validatedManifest({
  required List<LanSyncPluginDescriptor> plugins,
  required List<LanSyncShelfItem> shelfItems,
  required int skippedShelfItems,
}) {
  final manifest = LanSyncManifest(plugins: plugins, shelfItems: shelfItems, skippedShelfItems: skippedShelfItems);
  try {
    return LanSyncManifest.fromJson(manifest.toJson());
  } on FormatException catch (error, stackTrace) {
    Error.throwWithStackTrace(LanSyncGatewayException('manifest_invalid', reason: _safeManifestReason(error)), stackTrace);
  }
}

String _safeManifestReason(FormatException error) {
  final reason = error.message.toString();
  return RegExp(r'^[a-z0-9_]{3,96}$').hasMatch(reason) ? reason : 'invalid_manifest';
}

LanSyncShelfItem _toLanShelfItem(LibrarySyncItem item) => LanSyncShelfItem(
  pluginId: item.pluginId,
  pluginVersion: item.producerPluginVersion,
  remoteContentId: item.remoteContentId,
  contentKind: item.kind.code,
  title: item.title,
  author: item.author,
  coverUrl: item.coverUrl?.toString(),
  sourceName: item.sourceName,
  progress: item.progress == null ? null : _toLanProgress(item.progress!),
);

LanSyncReadingProgress _toLanProgress(LibrarySyncReadingProgress progress) => LanSyncReadingProgress(
  chapterId: progress.chapterId,
  paragraphId: progress.paragraphId,
  characterOffset: progress.characterOffset,
  chapterIndex: progress.chapterIndex,
  chapterFraction: progress.chapterFraction,
  bookFraction: progress.bookFraction,
  updatedAtUtc: progress.updatedAtUtc,
  totalReadingSeconds: progress.totalReadingSeconds,
);

LibrarySyncSnapshot _toLibrarySnapshot(LanSyncManifest manifest) => LibrarySyncSnapshot(
  items: List<LibrarySyncItem>.unmodifiable(
    manifest.shelfItems.map(
      (item) => LibrarySyncItem(
        pluginId: item.pluginId,
        producerPluginVersion: item.pluginVersion,
        remoteContentId: item.remoteContentId,
        kind: ContentKind.fromCode(item.contentKind)!,
        title: item.title,
        author: item.author,
        coverUrl: item.coverUrl == null ? null : Uri.tryParse(item.coverUrl!),
        sourceName: item.sourceName,
        progress: item.progress == null ? null : _toLibraryProgress(item.progress!),
      ),
    ),
  ),
  skippedSourceLessItems: manifest.skippedShelfItems,
);

LibrarySyncReadingProgress _toLibraryProgress(LanSyncReadingProgress value) => LibrarySyncReadingProgress(
  chapterId: value.chapterId,
  paragraphId: value.paragraphId,
  characterOffset: value.characterOffset,
  chapterIndex: value.chapterIndex,
  chapterFraction: value.chapterFraction,
  bookFraction: value.bookFraction,
  updatedAtUtc: value.updatedAtUtc,
  totalReadingSeconds: value.totalReadingSeconds,
);

String _identityText(LibrarySyncIdentity identity) => '${identity.pluginId}\u001f${identity.remoteContentId}';

LibrarySyncConflictChoice _toLibraryChoice(LanSyncConflictChoice choice) => switch (choice) {
  LanSyncConflictChoice.smartMerge => LibrarySyncConflictChoice.smartMerge,
  LanSyncConflictChoice.useSender => LibrarySyncConflictChoice.useSender,
  LanSyncConflictChoice.keepLocal => LibrarySyncConflictChoice.keepLocal,
};

String _runtimeFailureCode(Object error) {
  if (error is PluginRuntimeException) {
    final normalized = error.code.replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    if (normalized.isNotEmpty && normalized.length <= 64) {
      return 'runtime_$normalized';
    }
  }
  return 'runtime_transfer_failed';
}
