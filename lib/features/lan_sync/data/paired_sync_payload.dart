/// 已配对同步会话的 manifest、选择、制品流与应用事务。
///
/// 本文件是 paired_sync_transport.dart 的实现分片，不拥有发现或连接生命周期。
part of 'paired_sync_transport.dart';

final class _Selection {
  const _Selection({required this.pluginIds, required this.shelfItemIds});

  final Set<String> pluginIds;
  final Set<String> shelfItemIds;
}

final class _ImportPlan {
  const _ImportPlan({required this.developmentConflicts, required this.preview, required this.selection});

  final int developmentConflicts;
  final LanSyncImportPreview? preview;
  final _Selection selection;
}

final class _AppliedSummary {
  const _AppliedSummary({required this.books, required this.developmentConflicts, required this.plugins});

  const _AppliedSummary.empty({this.developmentConflicts = 0}) : books = 0, plugins = 0;

  final int books;
  final int developmentConflicts;
  final int plugins;

  Map<String, Object?> toJson() => <String, Object?>{'books': books, 'developmentConflicts': developmentConflicts, 'plugins': plugins};

  factory _AppliedSummary.fromJson(Map<String, Object?> json, {required String expectedType}) {
    final books = json['books'];
    final conflicts = json['developmentConflicts'];
    final plugins = json['plugins'];
    if (json['type'] != expectedType ||
        books is! int ||
        books < 0 ||
        books > lanSyncMaxShelfItemCount ||
        conflicts is! int ||
        conflicts < 0 ||
        plugins is! int ||
        plugins < 0) {
      throw const LanSyncTransportException('lan_sync_result_invalid');
    }
    return _AppliedSummary(books: books, developmentConflicts: conflicts, plugins: plugins);
  }
}

Future<_ImportPlan> _planImport(LanSyncGateway gateway, LanSyncManifest manifest) async {
  if (manifest.plugins.isEmpty && manifest.shelfItems.isEmpty) {
    return const _ImportPlan(
      developmentConflicts: 0,
      preview: null,
      selection: _Selection(pluginIds: <String>{}, shelfItemIds: <String>{}),
    );
  }
  final preview = await gateway.previewImport(manifest);
  return _ImportPlan(
    developmentConflicts: preview.pluginPlans.values.where((state) => state == LanSyncPluginPlanState.developmentConflict).length,
    preview: preview,
    selection: _Selection(pluginIds: preview.recommendedPluginIds, shelfItemIds: preview.selectedShelfItemIds),
  );
}

Future<void> _sendManifest(PairedSecureConnection connection, LanSyncManifest manifest) =>
    connection.sendControl(<String, Object?>{'type': 'manifest', 'value': manifest.toJson()}, maxBytes: lanSyncMaxManifestBytes);

Future<LanSyncManifest> _readManifest(PairedSecureConnection connection) async {
  final frame = await _readPairedSessionControl(connection, timeout: lanSyncTransferIdleTimeout, maxBytes: lanSyncMaxManifestBytes);
  final value = frame['value'];
  if (frame['type'] != 'manifest') {
    throw const LanSyncTransportException('lan_sync_manifest_invalid', reason: 'invalid_frame_type');
  }
  if (value is! Map) {
    throw const LanSyncTransportException('lan_sync_manifest_invalid', reason: 'invalid_manifest_value');
  }
  try {
    return LanSyncManifest.fromJson(_stringMap(value));
  } on FormatException catch (error, stackTrace) {
    Error.throwWithStackTrace(LanSyncTransportException('lan_sync_manifest_invalid', reason: _safeManifestReason(error)), stackTrace);
  }
}

Future<void> _sendSelection(PairedSecureConnection connection, _Selection selection) => connection.sendControl(<String, Object?>{
  'type': 'selection',
  'pluginIds': selection.pluginIds.toList(growable: false),
  'shelfItemIds': selection.shelfItemIds.toList(growable: false),
});

Future<_Selection> _readSelection(PairedSecureConnection connection, LanSyncManifest manifest) async {
  final frame = await _readPairedSessionControl(connection, timeout: lanSyncTransferIdleTimeout);
  final rawPlugins = frame['pluginIds'];
  final rawShelf = frame['shelfItemIds'];
  if (frame['type'] != 'selection' || rawPlugins is! List || rawShelf is! List) {
    throw const LanSyncTransportException('lan_sync_selection_invalid');
  }
  if (rawShelf.length > lanSyncMaxShelfItemCount ||
      rawPlugins.any((value) => value is! String) ||
      rawShelf.any((value) => value is! String)) {
    throw const LanSyncTransportException('lan_sync_selection_invalid');
  }
  final plugins = rawPlugins.cast<String>().toSet();
  final shelf = rawShelf.cast<String>().toSet();
  final availablePlugins = <String>{for (final item in manifest.plugins.where((item) => item.transferable)) item.id};
  final availableShelf = <String>{for (final item in manifest.shelfItems) item.identity};
  if (plugins.length != rawPlugins.length ||
      shelf.length != rawShelf.length ||
      !availablePlugins.containsAll(plugins) ||
      !availableShelf.containsAll(shelf)) {
    throw const LanSyncTransportException('lan_sync_selection_invalid');
  }
  return _Selection(pluginIds: plugins, shelfItemIds: shelf);
}

Future<void> _sendPayload(PairedSecureConnection connection, LanSyncGateway gateway, LanSyncManifest manifest, _Selection selection) async {
  final selected = manifest.plugins.where((item) => selection.pluginIds.contains(item.id)).toList(growable: false);
  final materialized = <LanSyncMaterializedPlugin>[];
  var completedStreams = 0;
  var expectedBytes = 0;
  try {
    for (final offer in selected) {
      final item = await _materializePlugin(gateway, offer);
      if (!_sameLogicalPlugin(item.descriptor, offer)) {
        throw const LanSyncTransportException('lan_sync_plugin_descriptor_invalid');
      }
      expectedBytes += item.descriptor.bytes;
      if (expectedBytes > lanSyncMaxBatchBytes) {
        throw const LanSyncTransportException('lan_sync_batch_too_large');
      }
      materialized.add(item);
    }
    await connection.sendControl(<String, Object?>{
      'type': 'payloadManifest',
      'plugins': materialized.map((item) => item.descriptor.toJson()).toList(growable: false),
    }, maxBytes: lanSyncMaxManifestBytes);
    var completedBytes = 0;
    for (var index = 0; index < materialized.length; index++) {
      final item = materialized[index];
      final plugin = item.descriptor;
      await connection.sendControl(<String, Object?>{'type': 'pluginBegin', 'plugin': plugin.toJson()});
      var pluginBytes = 0;
      await for (final rawChunk in item.bytes) {
        for (var offset = 0; offset < rawChunk.length;) {
          final end = min(rawChunk.length, offset + lanSyncPluginRelayChunkBytes);
          final chunk = Uint8List.fromList(rawChunk.sublist(offset, end));
          if (chunk.isNotEmpty) await connection.sendBinary(chunk);
          pluginBytes += chunk.length;
          completedBytes += chunk.length;
          offset = end;
        }
      }
      if (pluginBytes != plugin.bytes) throw const LanSyncTransportException('lan_sync_plugin_size_mismatch');
      await connection.sendControl(<String, Object?>{'type': 'pluginEnd', 'pluginId': plugin.id, 'bytes': pluginBytes});
      completedStreams = index + 1;
    }
    await connection.sendControl(<String, Object?>{
      'type': 'transferComplete',
      'pluginCount': materialized.length,
      'bytes': completedBytes,
    });
  } on Object {
    for (var index = completedStreams; index < materialized.length; index++) {
      await _cancelUnconsumed(materialized[index].bytes);
    }
    rethrow;
  }
}

Future<void> _cancelUnconsumed(Stream<List<int>> bytes) async {
  try {
    final subscription = bytes.listen((_) {}, onError: (Object _) {});
    await subscription.cancel();
  } on Object {
    // The active stream is already cancelled by await-for or fully consumed.
  }
}

Future<_AppliedSummary> _receivePayload(
  PairedSecureConnection connection,
  LanSyncGateway gateway,
  LanSyncManifest manifest,
  _ImportPlan plan,
) async {
  final selection = plan.selection;
  final offeredById = <String, LanSyncPluginDescriptor>{
    for (final plugin in manifest.plugins)
      if (selection.pluginIds.contains(plugin.id)) plugin.id: plugin,
  };
  final payloadFrame = await _readPairedSessionControl(connection, timeout: lanSyncTransferIdleTimeout, maxBytes: lanSyncMaxManifestBytes);
  final rawPlugins = payloadFrame['plugins'];
  if (payloadFrame['type'] != 'payloadManifest' || rawPlugins is! List || rawPlugins.length != offeredById.length) {
    throw const LanSyncTransportException('lan_sync_plugin_descriptor_invalid');
  }
  final selectedById = <String, LanSyncPluginDescriptor>{};
  var totalBytes = 0;
  for (final rawPlugin in rawPlugins) {
    if (rawPlugin is! Map) {
      throw const LanSyncTransportException('lan_sync_plugin_descriptor_invalid');
    }
    final plugin = LanSyncPluginDescriptor.fromJson(_stringMap(rawPlugin));
    final offer = offeredById[plugin.id];
    if (offer == null || selectedById.containsKey(plugin.id) || !_sameLogicalPlugin(plugin, offer)) {
      throw const LanSyncTransportException('lan_sync_plugin_descriptor_invalid');
    }
    totalBytes += plugin.bytes;
    if (totalBytes > lanSyncMaxBatchBytes) {
      throw const LanSyncTransportException('lan_sync_batch_too_large');
    }
    selectedById[plugin.id] = plugin;
  }
  var completedBytes = 0;
  final receivedIds = <String>{};
  try {
    await gateway.preparePluginImports(selectedById.values.toList(growable: false));
    while (true) {
      final frame = await connection.readFrame().timeout(lanSyncTransferIdleTimeout);
      _throwIfPairedSessionFailureFrame(frame);
      if (frame is! LanSyncControlFrame) throw const LanSyncTransportException('lan_sync_frame_unexpected');
      final value = frame.value;
      if (value['type'] == 'transferComplete') {
        if (receivedIds.length != selection.pluginIds.length ||
            !receivedIds.containsAll(selection.pluginIds) ||
            value['pluginCount'] != selection.pluginIds.length ||
            value['bytes'] != completedBytes ||
            completedBytes != totalBytes) {
          throw const LanSyncTransportException('lan_sync_transfer_incomplete');
        }
        break;
      }
      if (value['type'] != 'pluginBegin' || value['plugin'] is! Map) {
        throw const LanSyncTransportException('lan_sync_frame_unexpected');
      }
      final plugin = LanSyncPluginDescriptor.fromJson(_stringMap(value['plugin']! as Map));
      final expected = selectedById[plugin.id];
      if (expected == null || !receivedIds.add(plugin.id) || !_samePlugin(plugin, expected)) {
        throw const LanSyncTransportException('lan_sync_plugin_descriptor_invalid');
      }
      final controller = StreamController<List<int>>();
      Object? importError;
      StackTrace? importStackTrace;
      final observedImport = gateway
          .importPluginArchive(plugin, controller.stream)
          .then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {
              importError = error;
              importStackTrace = stackTrace;
            },
          );
      var pluginBytes = 0;
      try {
        while (pluginBytes < plugin.bytes) {
          final chunk = await connection.readFrame().timeout(lanSyncTransferIdleTimeout);
          _throwIfPairedSessionFailureFrame(chunk);
          if (chunk is! LanSyncBinaryFrame) {
            throw const LanSyncTransportException('lan_sync_plugin_frame_invalid');
          }
          pluginBytes += chunk.bytes.length;
          completedBytes += chunk.bytes.length;
          if (pluginBytes > plugin.bytes) {
            throw const LanSyncTransportException('lan_sync_plugin_size_mismatch');
          }
          controller.add(chunk.bytes);
        }
      } finally {
        if (!controller.isClosed) {
          await controller.close();
        }
      }
      final end = await _readPairedSessionControl(connection, timeout: lanSyncTransferIdleTimeout);
      if (end['type'] != 'pluginEnd' || end['pluginId'] != plugin.id || end['bytes'] != pluginBytes) {
        throw const LanSyncTransportException('lan_sync_plugin_size_mismatch');
      }
      await observedImport.timeout(lanSyncTransferIdleTimeout);
      if (importError != null) {
        Error.throwWithStackTrace(importError!, importStackTrace!);
      }
    }
    if (plan.preview == null) return _AppliedSummary.empty(developmentConflicts: plan.developmentConflicts);
    final pluginResult = await gateway.finishPluginImports();
    final selectedManifest = selection.shelfItemIds.length == manifest.shelfItems.length
        ? manifest
        : manifest.selectShelfItems(selection.shelfItemIds);
    final result = await gateway.applyImport(
      manifest: selectedManifest,
      conflictChoices: <String, LanSyncConflictChoice>{
        for (final conflict in plan.preview!.conflicts) conflict.identity: LanSyncConflictChoice.smartMerge,
      },
      availablePluginIds: pluginResult.availablePluginIds,
      pluginResult: pluginResult,
    );
    return _AppliedSummary(
      books: result.added + result.updated,
      developmentConflicts: plan.developmentConflicts,
      plugins: result.pluginInstalled,
    );
  } on Object {
    await gateway.cancelPluginImports();
    rethrow;
  }
}

bool _samePlugin(LanSyncPluginDescriptor left, LanSyncPluginDescriptor right) =>
    left.id == right.id &&
    left.version == right.version &&
    left.bytes == right.bytes &&
    left.artifactFormat == right.artifactFormat &&
    left.developmentFingerprint == right.developmentFingerprint &&
    left.developmentRevision == right.developmentRevision &&
    left.provenance == right.provenance &&
    left.sha256 == right.sha256 &&
    left.transferable;

Future<LanSyncManifest> _createPairedManifest(
  LanSyncGateway gateway, {
  required bool includePlugins,
  required bool includeShelf,
  required bool deferPluginArtifacts,
}) async {
  if (gateway is LanSyncPairedGateway) {
    return (gateway as LanSyncPairedGateway).createPairedManifest(
      includePlugins: includePlugins,
      includeShelf: includeShelf,
      deferPluginArtifacts: deferPluginArtifacts,
    );
  }
  final manifest = await gateway.createManifest();
  return LanSyncManifest(
    plugins: includePlugins ? manifest.plugins : const <LanSyncPluginDescriptor>[],
    shelfItems: includeShelf ? manifest.shelfItems : const <LanSyncShelfItem>[],
    skippedShelfItems: includeShelf ? manifest.skippedShelfItems : 0,
  );
}

Future<LanSyncMaterializedPlugin> _materializePlugin(LanSyncGateway gateway, LanSyncPluginDescriptor plugin) async {
  if (gateway is LanSyncPairedGateway) {
    return (gateway as LanSyncPairedGateway).materializePluginArchive(plugin);
  }
  return LanSyncMaterializedPlugin(descriptor: plugin, bytes: await gateway.openPluginArchive(plugin));
}

bool _sameLogicalPlugin(LanSyncPluginDescriptor materialized, LanSyncPluginDescriptor offer) =>
    materialized.id == offer.id &&
    materialized.version == offer.version &&
    materialized.artifactFormat == offer.artifactFormat &&
    materialized.developmentFingerprint == offer.developmentFingerprint &&
    materialized.developmentRevision == offer.developmentRevision &&
    materialized.provenance == offer.provenance &&
    materialized.transferable &&
    !materialized.deferred;

Map<String, Object?> _stringMap(Map<dynamic, dynamic> value) => value.map<String, Object?>((key, value) {
  if (key is! String) throw const LanSyncTransportException('lan_sync_control_invalid');
  return MapEntry(key, value);
});

String _safeManifestReason(FormatException error) {
  final reason = error.message.toString();
  return RegExp(r'^[a-z0-9_]{3,96}$').hasMatch(reason) ? reason : 'invalid_manifest';
}
