/// 本地导入导出应用服务与有界备份容器。
///
/// 职责：
/// - 让用户逐项选择数据源 artifact、书架和阅读进度并写入单个本地文件。
/// - 复用 Runtime artifact 与 Content Library 同步契约完成预览和事务导入。
///
/// 注意：
/// - Windows 桌面 development 数据源只能经 Runtime 构建为 artifact 后导出；本文件不读取项目目录或源码。
/// - 容器只串联 manifest 和原始 artifact 字节，不转换 single-file/archive，也不记录文件路径。
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' hide XFile;

import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

const int _bundleHeaderLimit = lanSyncMaxManifestBytes;
const List<int> _bundleMagic = <int>[0x4d, 0x47, 0x52, 0x45, 0x41, 0x44, 0x31, 0x0a];

final importExportCoordinatorProvider = Provider<ImportExportCoordinator>((Ref ref) {
  return ImportExportService(ref.watch(lanSyncGatewayProvider), const PlatformImportExportFilePicker());
});

abstract interface class ImportExportCoordinator {
  Future<ImportExportExportPlan> prepareExport();

  Future<bool> exportSelection(ImportExportExportPlan plan, {required Set<String> pluginIds, required Set<String> shelfItemIds});

  Future<ImportExportImportPlan?> pickImport();

  Future<LanSyncApplyResult> importSelection(
    ImportExportImportPlan plan, {
    required Set<String> pluginIds,
    required Set<String> shelfItemIds,
    required Map<String, LanSyncConflictChoice> conflictChoices,
  });
}

@immutable
final class ImportExportExportPlan {
  const ImportExportExportPlan(this.manifest);

  final LanSyncManifest manifest;

  Set<String> get defaultPluginIds => <String>{
    for (final plugin in manifest.plugins)
      if (plugin.transferable) plugin.id,
  };

  Set<String> get defaultShelfItemIds => <String>{for (final item in manifest.shelfItems) item.identity};
}

@immutable
final class ImportExportImportPlan {
  const ImportExportImportPlan._({required this.manifest, required this.preview, required this._bundle});

  final LanSyncManifest manifest;
  final LanSyncImportPreview preview;
  final _ParsedBundle _bundle;
}

abstract interface class ImportExportFilePicker {
  Future<String?> chooseExportPath(String suggestedName);

  Future<bool> completeExport(String path);

  Future<String?> chooseImportPath();
}

final class PlatformImportExportFilePicker implements ImportExportFilePicker {
  const PlatformImportExportFilePicker();

  static const XTypeGroup _bundleType = XTypeGroup(label: 'MgRead 备份', extensions: <String>['mgread']);

  @override
  Future<String?> chooseExportPath(String suggestedName) async {
    if (Platform.isAndroid) {
      final directory = await getTemporaryDirectory();
      return '${directory.path}${Platform.pathSeparator}$suggestedName';
    }
    if (!Platform.isWindows) throw const ImportExportException('unsupported_platform');
    final location = await getSaveLocation(
      acceptedTypeGroups: const <XTypeGroup>[_bundleType],
      suggestedName: suggestedName,
      confirmButtonText: '导出',
    );
    return location?.path;
  }

  @override
  Future<bool> completeExport(String path) async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          title: '导出 MgRead 备份',
          files: <XFile>[XFile(path, mimeType: 'application/octet-stream')],
        ),
      );
      return result.status != ShareResultStatus.dismissed;
    } finally {
      final temporary = File(path);
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  Future<String?> chooseImportPath() async {
    final file = await openFile(acceptedTypeGroups: const <XTypeGroup>[_bundleType], confirmButtonText: '导入');
    return file?.path;
  }
}

final class ImportExportService implements ImportExportCoordinator {
  const ImportExportService(this._gateway, this._filePicker);

  final LanSyncGateway _gateway;
  final ImportExportFilePicker _filePicker;

  @override
  Future<ImportExportExportPlan> prepareExport() async {
    // Runtime listExportableArtifacts builds a temporary artifact for every
    // Windows desktop development source. Only the resulting bytes reach here.
    return ImportExportExportPlan(await _gateway.createManifest());
  }

  @override
  Future<bool> exportSelection(ImportExportExportPlan plan, {required Set<String> pluginIds, required Set<String> shelfItemIds}) async {
    final plugins = <LanSyncPluginDescriptor>[
      for (final plugin in plan.manifest.plugins)
        if (pluginIds.contains(plugin.id) && plugin.transferable) plugin,
    ];
    final shelfItems = <LanSyncShelfItem>[
      for (final item in plan.manifest.shelfItems)
        if (shelfItemIds.contains(item.identity)) item,
    ];
    if (plugins.isEmpty && shelfItems.isEmpty) throw const ImportExportException('empty_selection');
    final manifest = LanSyncManifest(
      plugins: List<LanSyncPluginDescriptor>.unmodifiable(plugins),
      shelfItems: List<LanSyncShelfItem>.unmodifiable(shelfItems),
      skippedShelfItems: plan.manifest.skippedShelfItems,
    );
    final path = await _filePicker.chooseExportPath(_suggestedFileName(DateTime.now()));
    if (path == null || path.isEmpty) return false;
    final writtenPath = await _writeBundle(path, manifest);
    return _filePicker.completeExport(writtenPath);
  }

  @override
  Future<ImportExportImportPlan?> pickImport() async {
    final path = await _filePicker.chooseImportPath();
    if (path == null || path.isEmpty) return null;
    final bundle = await _readBundle(path);
    final preview = await _gateway.previewImport(bundle.manifest);
    return ImportExportImportPlan._(manifest: bundle.manifest, preview: preview, bundle: bundle);
  }

  @override
  Future<LanSyncApplyResult> importSelection(
    ImportExportImportPlan plan, {
    required Set<String> pluginIds,
    required Set<String> shelfItemIds,
    required Map<String, LanSyncConflictChoice> conflictChoices,
  }) async {
    final allowedPluginIds = plan.preview.recommendedPluginIds;
    final plugins = <LanSyncPluginDescriptor>[
      for (final plugin in plan.manifest.plugins)
        if (pluginIds.contains(plugin.id) && allowedPluginIds.contains(plugin.id)) plugin,
    ];
    final shelfItems = <LanSyncShelfItem>[
      for (final item in plan.manifest.shelfItems)
        if (shelfItemIds.contains(item.identity)) item,
    ];
    if (plugins.isEmpty && shelfItems.isEmpty) throw const ImportExportException('empty_selection');
    final manifest = LanSyncManifest(
      plugins: List<LanSyncPluginDescriptor>.unmodifiable(plugins),
      shelfItems: List<LanSyncShelfItem>.unmodifiable(shelfItems),
      skippedShelfItems: plan.manifest.skippedShelfItems,
    );
    try {
      await _gateway.previewImport(manifest);
      await _gateway.preparePluginImports(plugins);
      for (final plugin in plugins) {
        final segment = plan._bundle.segments[plugin.id];
        if (segment == null) throw const ImportExportException('invalid_bundle');
        await _gateway.importPluginArchive(plugin, File(plan._bundle.path).openRead(segment.start, segment.end));
      }
      final pluginResult = await _gateway.finishPluginImports();
      return await _gateway.applyImport(
        manifest: manifest,
        conflictChoices: conflictChoices,
        availablePluginIds: pluginResult.availablePluginIds,
        pluginResult: pluginResult,
      );
    } on Object {
      await _gateway.cancelPluginImports();
      rethrow;
    }
  }

  Future<String> _writeBundle(String selectedPath, LanSyncManifest manifest) async {
    final path = selectedPath.toLowerCase().endsWith('.mgread') ? selectedPath : '$selectedPath.mgread';
    final header = utf8.encode(jsonEncode(<String, Object?>{'schemaVersion': 1, 'manifest': manifest.toJson()}));
    if (header.length > _bundleHeaderLimit) throw const ImportExportException('bundle_too_large');
    final headerSize = ByteData(4)..setUint32(0, header.length, Endian.big);
    final temporary = File('$path.part');
    final target = File(path);
    final backup = File('$path.previous-${DateTime.now().microsecondsSinceEpoch}');
    IOSink? sink;
    var targetMoved = false;
    try {
      if (await temporary.exists()) await temporary.delete();
      sink = temporary.openWrite(mode: FileMode.writeOnly);
      sink.add(_bundleMagic);
      sink.add(headerSize.buffer.asUint8List());
      sink.add(header);
      for (final plugin in manifest.plugins) {
        var written = 0;
        final stream = await _gateway.openPluginArchive(plugin);
        await sink.addStream(
          stream.map((chunk) {
            written += chunk.length;
            if (written > plugin.bytes) throw const ImportExportException('invalid_artifact_length');
            return chunk;
          }),
        );
        if (written != plugin.bytes) throw const ImportExportException('invalid_artifact_length');
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (await target.exists()) {
        await target.rename(backup.path);
        targetMoved = true;
      }
      await temporary.rename(path);
      if (targetMoved && await backup.exists()) {
        try {
          await backup.delete();
        } on FileSystemException {
          // A stale recovery copy is safer than failing an already-complete export.
        }
      }
      return path;
    } on Object {
      await sink?.close();
      if (await temporary.exists()) await temporary.delete();
      if (targetMoved && await backup.exists() && !await target.exists()) {
        await backup.rename(path);
      }
      rethrow;
    }
  }
}

Future<_ParsedBundle> _readBundle(String path) async {
  final file = File(path);
  final metadata = await file.stat();
  if (metadata.type != FileSystemEntityType.file || metadata.size < _bundleMagic.length + 4) {
    throw const ImportExportException('invalid_bundle');
  }
  final handle = await file.open();
  try {
    final magic = await _readExactly(handle, _bundleMagic.length);
    if (!listEquals(magic, _bundleMagic)) throw const ImportExportException('invalid_bundle');
    final lengthBytes = await _readExactly(handle, 4);
    final headerLength = ByteData.sublistView(Uint8List.fromList(lengthBytes)).getUint32(0, Endian.big);
    if (headerLength <= 0 || headerLength > _bundleHeaderLimit) throw const ImportExportException('invalid_bundle');
    final decoded = jsonDecode(utf8.decode(await _readExactly(handle, headerLength)));
    if (decoded is! Map || decoded['schemaVersion'] != 1 || decoded['manifest'] is! Map) {
      throw const ImportExportException('invalid_bundle');
    }
    final manifest = LanSyncManifest.fromJson(Map<String, Object?>.from(decoded['manifest'] as Map));
    if (manifest.plugins.any((plugin) => !plugin.transferable)) throw const ImportExportException('invalid_bundle');
    var offset = _bundleMagic.length + 4 + headerLength;
    final segments = <String, _BundleSegment>{};
    for (final plugin in manifest.plugins) {
      final end = offset + plugin.bytes;
      if (end > metadata.size) throw const ImportExportException('invalid_bundle');
      segments[plugin.id] = _BundleSegment(offset, end);
      offset = end;
    }
    if (offset != metadata.size) throw const ImportExportException('invalid_bundle');
    return _ParsedBundle(path: path, manifest: manifest, segments: Map<String, _BundleSegment>.unmodifiable(segments));
  } on FormatException {
    throw const ImportExportException('invalid_bundle');
  } finally {
    await handle.close();
  }
}

Future<List<int>> _readExactly(RandomAccessFile file, int length) async {
  final bytes = <int>[];
  while (bytes.length < length) {
    final chunk = await file.read(length - bytes.length);
    if (chunk.isEmpty) throw const ImportExportException('invalid_bundle');
    bytes.addAll(chunk);
  }
  return bytes;
}

String _suggestedFileName(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return 'mgread-${value.year}${two(value.month)}${two(value.day)}.mgread';
}

final class _ParsedBundle {
  const _ParsedBundle({required this.path, required this.manifest, required this.segments});
  final String path;
  final LanSyncManifest manifest;
  final Map<String, _BundleSegment> segments;
}

final class _BundleSegment {
  const _BundleSegment(this.start, this.end);
  final int start;
  final int end;
}

final class ImportExportException implements Exception {
  const ImportExportException(this.code);
  final String code;
}
