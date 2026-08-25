import 'dart:async';

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

/// Bridges the app-owned library and the path-free Runtime transfer facade.
final class MgReadLanSyncGateway implements LanSyncGateway {
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
  final Map<String, StreamController<List<int>>> _importControllers =
      <String, StreamController<List<int>>>{};
  Future<List<PluginTransferImportResult>>? _batchImport;

  @override
  Future<LanSyncManifest> createManifest() async {
    final results = await Future.wait<Object>(<Future<Object>>[
      _library.createSyncSnapshot(),
      _runtime.invoke(const InstalledPluginsInvocation()),
      _runtime.invoke(const PluginTransferListInvocation()),
    ]);
    final snapshot = results[0] as LibrarySyncSnapshot;
    final installed = results[1] as List<InstalledPlugin>;
    final archives = results[2] as List<PluginTransferArchive>;
    final installedById = <String, InstalledPlugin>{
      for (final plugin in installed) plugin.id: plugin,
    };
    final archivesById = <String, PluginTransferArchive>{
      for (final archive in archives) archive.pluginId: archive,
    };
    final requestedVersions = <String, String>{
      for (final item in snapshot.items)
        item.pluginId: item.producerPluginVersion,
      for (final plugin in installed)
        if (plugin.activeVersion != null)
          plugin.id: plugin.status == 'development'
              ? archivesById[plugin.id]?.version ?? plugin.activeVersion!
              : plugin.activeVersion!,
    };
    if (requestedVersions.length > lanSyncMaxPluginCount) {
      throw StateError('lan_sync_plugin_count_exceeded');
    }
    final plugins = <LanSyncPluginDescriptor>[];
    for (final entry in requestedVersions.entries) {
      final archive = _findArchive(archives, entry.key, entry.value);
      final installedPlugin = installedById[entry.key];
      plugins.add(
        LanSyncPluginDescriptor(
          id: entry.key,
          version: entry.value,
          bytes: archive?.bytes ?? 0,
          sha256: archive?.sha256 ?? ''.padLeft(64, '0'),
          transferable: archive != null,
          displayName: installedPlugin?.displayName,
          reason: archive == null ? 'archive_unavailable' : null,
        ),
      );
    }
    return LanSyncManifest(
      plugins: List<LanSyncPluginDescriptor>.unmodifiable(plugins),
      shelfItems: List<LanSyncShelfItem>.unmodifiable(
        snapshot.items.map(_toLanShelfItem),
      ),
      skippedShelfItems: snapshot.skippedSourceLessItems,
    );
  }

  @override
  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin) {
    if (!plugin.transferable) {
      throw StateError('lan_sync_plugin_archive_unavailable');
    }
    return _runtime.exportPluginArchive(_toRuntimeArchive(plugin));
  }

  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest) async {
    _installed = 0;
    _skipped = 0;
    _failed = 0;
    final installed = await _runtime.invoke(const InstalledPluginsInvocation());
    final installedIds = installed.map((plugin) => plugin.id).toSet();
    final installedById = <String, InstalledPlugin>{
      for (final plugin in installed) plugin.id: plugin,
    };
    final transferable = manifest.plugins
        .where((plugin) => plugin.transferable)
        .map(_toRuntimeArchive)
        .toList(growable: false);
    final plans = transferable.isEmpty
        ? const <PluginTransferPlanItem>[]
        : await _runtime.invoke(
            PluginTransferPlanInvocation(archives: transferable),
          );
    final planById = <String, PluginTransferPlanItem>{
      for (final plan in plans) plan.pluginId: plan,
    };
    final featurePlans = <String, LanSyncPluginPlanState>{};
    final availableAfterTransfer = <String>{...installedIds};
    for (final plugin in manifest.plugins) {
      final plan = planById[plugin.id];
      final state = plan == null
          ? _planUnavailableArchive(plugin, installedById[plugin.id])
          : _toFeaturePlan(plan.action);
      featurePlans[plugin.id] = state;
      if (state == LanSyncPluginPlanState.missing ||
          state == LanSyncPluginPlanState.upgrade) {
        availableAfterTransfer.add(plugin.id);
      }
      if (state == LanSyncPluginPlanState.sameVersion ||
          state == LanSyncPluginPlanState.receiverNewer) {
        _skipped++;
      }
    }
    final snapshot = _toLibrarySnapshot(manifest);
    final preview = await _library.previewSyncSnapshot(
      snapshot,
      availablePluginIds: availableAfterTransfer,
    );
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
      pluginPlans: Map<String, LanSyncPluginPlanState>.unmodifiable(
        featurePlans,
      ),
    );
  }

  @override
  Future<void> preparePluginImports(
    List<LanSyncPluginDescriptor> plugins,
  ) async {
    await cancelPluginImports();
    _preparedCount = plugins.length;
    if (plugins.isEmpty) return;
    for (final plugin in plugins) {
      if (!plugin.transferable || _importControllers.containsKey(plugin.id)) {
        throw StateError('lan_sync_plugin_selection_invalid');
      }
      _importControllers[plugin.id] = StreamController<List<int>>();
    }
    _batchImport = _runtime.importPluginArchives(
      <({PluginTransferArchive archive, Stream<List<int>> bytes})>[
        for (final plugin in plugins)
          (
            archive: _toRuntimeArchive(plugin),
            bytes: _importControllers[plugin.id]!.stream,
          ),
      ],
    );
  }

  @override
  Future<void> importPluginArchive(
    LanSyncPluginDescriptor plugin,
    Stream<List<int>> bytes,
  ) async {
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
        _installed += results
            .where(
              (result) => result.status == PluginTransferImportStatus.installed,
            )
            .length;
        _failed += results
            .where(
              (result) => result.status == PluginTransferImportStatus.failed,
            )
            .length;
      } on Object {
        _failed += _preparedCount;
      }
    }
    _preparedCount = 0;
    final installed = await _runtime.invoke(const InstalledPluginsInvocation());
    return LanSyncPluginImportResult(
      availablePluginIds: Set<String>.unmodifiable(
        installed.map((plugin) => plugin.id),
      ),
      installed: _installed,
      skipped: _skipped,
      failed: _failed,
    );
  }

  @override
  Future<void> cancelPluginImports() async {
    final controllers = _importControllers.values.toList(growable: false);
    _importControllers.clear();
    for (final controller in controllers) {
      if (!controller.isClosed) await controller.close();
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
    if (!identical(_pendingManifest, manifest) ||
        snapshot == null ||
        preview == null) {
      snapshot = _toLibrarySnapshot(manifest);
      preview = await _library.previewSyncSnapshot(
        snapshot,
        availablePluginIds: availablePluginIds,
      );
    } else if (pluginResult.failed > 0) {
      preview = await _library.previewSyncSnapshot(
        snapshot,
        availablePluginIds: availablePluginIds,
      );
    }
    final choices = <LibrarySyncIdentity, LibrarySyncConflictChoice>{};
    var keptLocal = 0;
    for (final conflict in preview.conflicts) {
      final choice =
          conflictChoices[_identityText(conflict.identity)] ??
          LanSyncConflictChoice.smartMerge;
      choices[conflict.identity] = _toLibraryChoice(choice);
      if (choice == LanSyncConflictChoice.keepLocal) keptLocal++;
    }
    final result = await _library.applySyncSnapshot(
      snapshot,
      preview: preview,
      choices: choices,
    );
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

PluginTransferArchive? _findArchive(
  List<PluginTransferArchive> archives,
  String pluginId,
  String version,
) {
  for (final archive in archives) {
    if (archive.pluginId == pluginId && archive.version == version) {
      return archive;
    }
  }
  return null;
}

PluginTransferArchive _toRuntimeArchive(LanSyncPluginDescriptor plugin) =>
    PluginTransferArchive(
      bytes: plugin.bytes,
      pluginId: plugin.id,
      sha256: plugin.sha256,
      version: plugin.version,
    );

LanSyncPluginPlanState _toFeaturePlan(PluginTransferPlanAction action) =>
    switch (action) {
      PluginTransferPlanAction.missing => LanSyncPluginPlanState.missing,
      PluginTransferPlanAction.upgrade => LanSyncPluginPlanState.upgrade,
      PluginTransferPlanAction.same => LanSyncPluginPlanState.sameVersion,
      PluginTransferPlanAction.receiverNewer =>
        LanSyncPluginPlanState.receiverNewer,
      PluginTransferPlanAction.unavailable =>
        LanSyncPluginPlanState.unavailable,
    };

LanSyncPluginPlanState _planUnavailableArchive(
  LanSyncPluginDescriptor sender,
  InstalledPlugin? receiver,
) {
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
  final leftParts = <int>[
    int.parse(leftMatch.group(1)!),
    int.parse(leftMatch.group(2)!),
    int.parse(leftMatch.group(3)!),
  ];
  final rightParts = <int>[
    int.parse(rightMatch.group(1)!),
    int.parse(rightMatch.group(2)!),
    int.parse(rightMatch.group(3)!),
  ];
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
  final sharedLength = leftIdentifiers.length < rightIdentifiers.length
      ? leftIdentifiers.length
      : rightIdentifiers.length;
  for (var index = 0; index < sharedLength; index++) {
    final leftNumber = int.tryParse(leftIdentifiers[index]);
    final rightNumber = int.tryParse(rightIdentifiers[index]);
    if (leftNumber != null &&
        rightNumber != null &&
        leftNumber != rightNumber) {
      return leftNumber.compareTo(rightNumber);
    }
    if (leftNumber != null && rightNumber == null) return -1;
    if (leftNumber == null && rightNumber != null) return 1;
    final textComparison = leftIdentifiers[index].compareTo(
      rightIdentifiers[index],
    );
    if (textComparison != 0) return textComparison;
  }
  return leftIdentifiers.length.compareTo(rightIdentifiers.length);
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

LanSyncReadingProgress _toLanProgress(LibrarySyncReadingProgress progress) =>
    LanSyncReadingProgress(
      chapterId: progress.chapterId,
      paragraphId: progress.paragraphId,
      characterOffset: progress.characterOffset,
      chapterIndex: progress.chapterIndex,
      chapterFraction: progress.chapterFraction,
      bookFraction: progress.bookFraction,
      updatedAtUtc: progress.updatedAtUtc,
      totalReadingSeconds: progress.totalReadingSeconds,
    );

LibrarySyncSnapshot _toLibrarySnapshot(LanSyncManifest manifest) =>
    LibrarySyncSnapshot(
      items: List<LibrarySyncItem>.unmodifiable(
        manifest.shelfItems.map(
          (item) => LibrarySyncItem(
            pluginId: item.pluginId,
            producerPluginVersion: item.pluginVersion,
            remoteContentId: item.remoteContentId,
            kind: ContentKind.fromCode(item.contentKind)!,
            title: item.title,
            author: item.author,
            coverUrl: item.coverUrl == null
                ? null
                : Uri.tryParse(item.coverUrl!),
            sourceName: item.sourceName,
            progress: item.progress == null
                ? null
                : _toLibraryProgress(item.progress!),
          ),
        ),
      ),
      skippedSourceLessItems: manifest.skippedShelfItems,
    );

LibrarySyncReadingProgress _toLibraryProgress(LanSyncReadingProgress value) =>
    LibrarySyncReadingProgress(
      chapterId: value.chapterId,
      paragraphId: value.paragraphId,
      characterOffset: value.characterOffset,
      chapterIndex: value.chapterIndex,
      chapterFraction: value.chapterFraction,
      bookFraction: value.bookFraction,
      updatedAtUtc: value.updatedAtUtc,
      totalReadingSeconds: value.totalReadingSeconds,
    );

String _identityText(LibrarySyncIdentity identity) =>
    '${identity.pluginId}\u001f${identity.remoteContentId}';

LibrarySyncConflictChoice _toLibraryChoice(LanSyncConflictChoice choice) =>
    switch (choice) {
      LanSyncConflictChoice.smartMerge => LibrarySyncConflictChoice.smartMerge,
      LanSyncConflictChoice.useSender => LibrarySyncConflictChoice.useSender,
      LanSyncConflictChoice.keepLocal => LibrarySyncConflictChoice.keepLocal,
    };
