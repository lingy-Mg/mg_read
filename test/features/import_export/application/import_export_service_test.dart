/// 本地导入导出容器与应用编排回归测试。
///
/// 验证 artifact 原样写入、逐项选择和导入事务；测试不启动真实 Runtime 或文件选择器。
library;

import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/import_export/application/import_export_service.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

void main() {
  test('round trips selected packaged artifact and shelf item without a source tree', () async {
    final directory = await Directory.systemTemp.createTemp('mgread-import-export-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}selected.mgread';
    final sender = _FakeGateway(_manifest, artifactBytes: <int>[1, 3, 5, 7, 9]);
    final picker = _FakeFilePicker(path);
    final exporter = ImportExportService(sender, picker);

    final exportPlan = await exporter.prepareExport();
    final exported = await exporter.exportSelection(exportPlan, pluginIds: <String>{_plugin.id}, shelfItemIds: <String>{_book.identity});

    expect(exported, isTrue);
    expect(sender.openedPluginIds, <String>[_plugin.id]);
    expect(await File(path).exists(), isTrue);

    final receiver = _FakeGateway(
      const LanSyncManifest(plugins: <LanSyncPluginDescriptor>[], shelfItems: <LanSyncShelfItem>[], skippedShelfItems: 0),
    );
    final importer = ImportExportService(receiver, picker);
    final importPlan = await importer.pickImport();

    expect(importPlan, isNotNull);
    expect(importPlan!.manifest.plugins.single.id, _plugin.id);
    expect(importPlan.manifest.shelfItems.single.identity, _book.identity);

    final result = await importer.importSelection(
      importPlan,
      pluginIds: <String>{_plugin.id},
      shelfItemIds: <String>{_book.identity},
      conflictChoices: const <String, LanSyncConflictChoice>{},
    );

    expect(receiver.importedBytes[_plugin.id], <int>[1, 3, 5, 7, 9]);
    expect(receiver.appliedManifest?.plugins.single.id, _plugin.id);
    expect(receiver.appliedManifest?.shelfItems.single.identity, _book.identity);
    expect(result.pluginInstalled, 1);
    expect(result.added, 1);
  });

  test('writes only selected categories into the bundle manifest', () async {
    final directory = await Directory.systemTemp.createTemp('mgread-import-export-selection-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}books-only.mgread';
    final sender = _FakeGateway(_manifest, artifactBytes: <int>[1, 3, 5, 7, 9]);
    final picker = _FakeFilePicker(path);
    final service = ImportExportService(sender, picker);

    await service.exportSelection(await service.prepareExport(), pluginIds: const <String>{}, shelfItemIds: <String>{_book.identity});
    final plan = await service.pickImport();

    expect(plan!.manifest.plugins, isEmpty);
    expect(plan.manifest.shelfItems.single.identity, _book.identity);
    expect(sender.openedPluginIds, isEmpty);
  });

  test('reads the previous v1 backup container and v2 manifest', () async {
    final directory = await Directory.systemTemp.createTemp('mgread-import-export-v1-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}legacy.mgread';
    final legacyManifest = <String, Object?>{
      'schemaVersion': 2,
      'plugins': <Object?>[_plugin.toJson()],
      'shelfItems': <Object?>[],
      'skippedShelfItems': 0,
    };
    final header = utf8.encode(jsonEncode(<String, Object?>{'schemaVersion': 1, 'manifest': legacyManifest}));
    final length = ByteData(4)..setUint32(0, header.length, Endian.big);
    await File(
      path,
    ).writeAsBytes(<int>[0x4d, 0x47, 0x52, 0x45, 0x41, 0x44, 0x31, 0x0a, ...length.buffer.asUint8List(), ...header, 1, 3, 5, 7, 9]);
    final gateway = _FakeGateway(
      const LanSyncManifest(plugins: <LanSyncPluginDescriptor>[], shelfItems: <LanSyncShelfItem>[], skippedShelfItems: 0),
    );
    final service = ImportExportService(gateway, _FakeFilePicker(path));

    final plan = (await service.pickImport())!;
    expect(plan.manifest.localDocuments, isEmpty);
    expect(plan.manifest.plugins.single.id, _plugin.id);
    await service.importSelection(
      plan,
      pluginIds: <String>{_plugin.id},
      shelfItemIds: const <String>{},
      conflictChoices: const <String, LanSyncConflictChoice>{},
    );
    expect(gateway.importedBytes[_plugin.id], <int>[1, 3, 5, 7, 9]);
  });
}

const _plugin = LanSyncPluginDescriptor(
  id: 'org.example.packaged',
  version: '1.2.3',
  bytes: 5,
  artifactFormat: LanSyncPluginArtifactFormat.singleFile,
  checksum: 'aaaaaaaa',
  transferable: true,
  displayName: '已打包数据源',
);

final _book = LanSyncShelfItem(
  pluginId: _plugin.id,
  pluginVersion: _plugin.version,
  remoteContentId: 'book-1',
  contentKind: 'novel',
  title: '测试书籍',
  progress: LanSyncReadingProgress(
    chapterId: 'chapter-1',
    paragraphId: 'paragraph-1',
    characterOffset: 2,
    chapterIndex: 0,
    chapterFraction: 0.2,
    bookFraction: 0.1,
    updatedAtUtc: DateTime.utc(2026, 8, 29),
    totalReadingSeconds: 60,
  ),
);

final _manifest = LanSyncManifest(
  plugins: const <LanSyncPluginDescriptor>[_plugin],
  shelfItems: <LanSyncShelfItem>[_book],
  skippedShelfItems: 0,
);

final class _FakeFilePicker implements ImportExportFilePicker {
  const _FakeFilePicker(this.path);
  final String path;

  @override
  Future<String?> chooseExportPath(String suggestedName) async => path;

  @override
  Future<bool> completeExport(String path) async => true;

  @override
  Future<String?> chooseImportPath() async => path;
}

final class _FakeGateway implements LanSyncGateway {
  _FakeGateway(this.manifest, {this.artifactBytes = const <int>[]});

  final LanSyncManifest manifest;
  final List<int> artifactBytes;
  final List<String> openedPluginIds = <String>[];
  final Map<String, List<int>> importedBytes = <String, List<int>>{};
  LanSyncManifest? appliedManifest;

  @override
  Future<LanSyncManifest> createManifest() async => manifest;

  @override
  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin) async {
    openedPluginIds.add(plugin.id);
    return Stream<List<int>>.value(artifactBytes);
  }

  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest, {bool force = false}) async => LanSyncImportPreview(
    newItemCount: manifest.shelfItems.length,
    conflicts: const <LanSyncBookConflict>[],
    blockedItemCount: 0,
    pluginPlans: <String, LanSyncPluginPlanState>{for (final plugin in manifest.plugins) plugin.id: LanSyncPluginPlanState.missing},
    selectedPluginIds: <String>{for (final plugin in manifest.plugins) plugin.id},
    selectedShelfItemIds: <String>{for (final item in manifest.shelfItems) item.identity},
  );

  @override
  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins, {Set<String> forceUpgradePluginIds = const <String>{}}) async {}

  @override
  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) async {
    importedBytes[plugin.id] = <int>[await for (final chunk in bytes) ...chunk];
  }

  @override
  Future<LanSyncPluginImportResult> finishPluginImports() async => LanSyncPluginImportResult(
    availablePluginIds: <String>{...importedBytes.keys},
    installed: importedBytes.length,
    skipped: 0,
    failed: 0,
  );

  @override
  Future<void> cancelPluginImports() async {}

  @override
  Future<LanSyncApplyResult> applyImport({
    required LanSyncManifest manifest,
    required Map<String, LanSyncConflictChoice> conflictChoices,
    required Set<String> availablePluginIds,
    required LanSyncPluginImportResult pluginResult,
    bool force = false,
  }) async {
    appliedManifest = manifest;
    return LanSyncApplyResult(
      added: manifest.shelfItems.length,
      updated: 0,
      keptLocal: 0,
      blocked: 0,
      pluginInstalled: pluginResult.installed,
      pluginSkipped: pluginResult.skipped,
      pluginFailed: pluginResult.failed,
    );
  }
}
