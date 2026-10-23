/// Reads offline Node collections and the static GitHub plugin catalog.
///
/// Catalog metadata and downloaded plugin hashes are validated before Runtime
/// import. ZIP metadata is checked before any payload is decompressed.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';

import 'plugin_runtime_models.dart';

const int sourceCollectionMaxArchiveBytes = 512 * 1024 * 1024;
const int sourceCollectionMaxManifestBytes = 1024 * 1024;
const int sourceCollectionMaxPlugins = 256;

final sourceCollectionImportServiceProvider = Provider<SourceCollectionImportService>(
  (Ref ref) => const SourceCollectionImportService(PlatformSourceCollectionFilePicker()),
);

final Uri defaultOnlinePluginCatalogUri = Uri.https('github.com', '/lingy-Mg/mg_read/releases/download/source-catalog/catalog.json');

final onlineSourceCatalogServiceProvider = Provider<OnlineSourceCatalogService>(
  (Ref ref) => OnlineSourceCatalogService(
    httpClientFactory: () => ref.read(configuredFlutterNetworkProxyManagerProvider).createHttpClient(NetworkProxyTraffic.sourceHttp),
  ),
);

abstract interface class SourceCollectionFilePicker {
  Future<String?> chooseCollectionPath();
}

final class PlatformSourceCollectionFilePicker implements SourceCollectionFilePicker {
  const PlatformSourceCollectionFilePicker();

  @override
  Future<String?> chooseCollectionPath() async {
    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: 'MgRead 数据源合集', extensions: <String>['mgplugins']),
      ],
      confirmButtonText: '打开',
    );
    return file?.path;
  }
}

final class SourceCollectionImportService {
  const SourceCollectionImportService(this._picker);

  final SourceCollectionFilePicker _picker;

  Future<SourceCollection?> pickCollection() async {
    final path = await _picker.chooseCollectionPath();
    if (path == null) return null;
    try {
      final file = File(path);
      final length = await file.length();
      if (length <= 0 || length > sourceCollectionMaxArchiveBytes) {
        throw const SourceCollectionImportException('合集压缩包为空或超过 512 MiB。');
      }
      return parseSourceCollection(await file.readAsBytes());
    } on SourceCollectionImportException {
      rethrow;
    } on Object {
      throw const SourceCollectionImportException('无法读取所选数据源合集文件。请检查文件权限后重试。');
    }
  }
}

/// Reads the static GitHub plugin repository and verifies each selected asset.
final class OnlineSourceCatalogService {
  OnlineSourceCatalogService({required this.httpClientFactory, Uri? catalogUri}) : catalogUri = catalogUri ?? defaultOnlinePluginCatalogUri;

  final Future<HttpClient> Function() httpClientFactory;
  final Uri catalogUri;

  Future<SourceCollection> loadCatalog() async {
    final client = await httpClientFactory();
    try {
      final request = await client.getUrl(catalogUri).timeout(const Duration(seconds: 30));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        throw const SourceCollectionImportException('GitHub 插件仓库暂时无法访问。');
      }
      final bytes = await _readBoundedResponse(response, sourceCollectionMaxManifestBytes);
      return _parseOnlineCatalog(bytes, (entry) => _downloadOnlinePlugin(entry));
    } on SourceCollectionImportException {
      rethrow;
    } on Object {
      throw const SourceCollectionImportException('无法读取 GitHub 插件仓库，请检查网络后重试。');
    } finally {
      client.close(force: true);
    }
  }

  Stream<List<int>> _downloadOnlinePlugin(_OnlineCatalogEntry entry) async* {
    final client = await httpClientFactory();
    try {
      final request = await client.getUrl(entry.url).timeout(const Duration(seconds: 30));
      request.headers.set(HttpHeaders.acceptHeader, 'application/javascript, text/javascript');
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        throw const SourceCollectionImportException('GitHub 插件文件下载失败。');
      }
      final bytes = await _readBoundedResponse(response, maxPluginTransferBytes);
      if (bytes.length != entry.bytes ||
          sha256.convert(bytes).toString() != entry.sha256 ||
          getCrc32(bytes).toRadixString(16).padLeft(8, '0') != entry.crc32) {
        throw const SourceCollectionImportException('插件文件与仓库清单中的大小或校验值不匹配。');
      }
      yield bytes;
    } on SourceCollectionImportException {
      rethrow;
    } on Object {
      throw const SourceCollectionImportException('插件文件下载中断，请检查网络后重试。');
    } finally {
      client.close(force: true);
    }
  }
}

Future<Uint8List> _readBoundedResponse(HttpClientResponse response, int maxBytes) async {
  if (response.contentLength > maxBytes) {
    throw const SourceCollectionImportException('GitHub 返回的文件超过允许大小。');
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response.timeout(const Duration(seconds: 60))) {
    if (builder.length + chunk.length > maxBytes) {
      throw const SourceCollectionImportException('GitHub 返回的文件超过允许大小。');
    }
    builder.add(chunk);
  }
  final bytes = builder.takeBytes();
  if (bytes.isEmpty) throw const SourceCollectionImportException('GitHub 返回了空文件。');
  return bytes;
}

SourceCollection _parseOnlineCatalog(Uint8List bytes, Stream<List<int>> Function(_OnlineCatalogEntry) openBytes) {
  late final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
  } on Object {
    throw const SourceCollectionImportException('GitHub 插件仓库清单无法解析。');
  }
  if (decoded is! Map<String, dynamic> ||
      decoded.keys.toSet().difference(<String>{'format', 'schemaVersion', 'plugins'}).isNotEmpty ||
      decoded['format'] != 'mgread-online-plugin-catalog' ||
      decoded['schemaVersion'] != 1 ||
      decoded['plugins'] is! List<dynamic>) {
    throw const SourceCollectionImportException('GitHub 插件仓库清单格式或版本不受支持。');
  }
  final rows = decoded['plugins'] as List<dynamic>;
  if (rows.isEmpty || rows.length > sourceCollectionMaxPlugins) {
    throw const SourceCollectionImportException('GitHub 插件仓库项目数量无效。');
  }
  final ids = <String>{};
  var totalBytes = 0;
  final plugins = <SourceCollectionPlugin>[];
  for (final row in rows) {
    if (row is! Map<String, dynamic> ||
        row.keys.toSet().difference(<String>{'id', 'name', 'version', 'format', 'path', 'url', 'bytes', 'crc32', 'sha256'}).isNotEmpty) {
      throw const SourceCollectionImportException('GitHub 插件仓库包含无效项目。');
    }
    final id = row['id'];
    final name = row['name'];
    final version = row['version'];
    final format = row['format'];
    final path = row['path'];
    final url = Uri.tryParse(row['url'] is String ? row['url'] as String : '');
    final size = row['bytes'];
    final crc32 = row['crc32'];
    final sha = row['sha256'];
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(id) ||
        !ids.add(id) ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 200 ||
        version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$').hasMatch(version) ||
        format != 'singleFile' ||
        path != 'plugins/$id.mgplugin.js' ||
        url == null ||
        url.scheme != 'https' ||
        url.host != 'github.com' ||
        !url.path.startsWith('/lingy-Mg/mg_read/releases/download/source-catalog/') ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        size is! int ||
        size <= 0 ||
        size > maxPluginTransferBytes ||
        crc32 is! String ||
        !RegExp(r'^[a-f0-9]{8}$').hasMatch(crc32) ||
        sha is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha)) {
      throw const SourceCollectionImportException('GitHub 插件仓库清单字段无效或包含重复项目。');
    }
    totalBytes += size;
    if (totalBytes > maxPluginTransferBatchBytes) {
      throw const SourceCollectionImportException('GitHub 插件仓库总大小超过 512 MiB。');
    }
    final entry = _OnlineCatalogEntry(url: url, bytes: size, crc32: crc32, sha256: sha);
    plugins.add(
      SourceCollectionPlugin(
        id: id,
        name: name.trim(),
        version: version,
        format: 'singleFile',
        byteLength: size,
        checksum: crc32,
        openBytes: () => openBytes(entry),
      ),
    );
  }
  return SourceCollection(List<SourceCollectionPlugin>.unmodifiable(plugins));
}

final class _OnlineCatalogEntry {
  const _OnlineCatalogEntry({required this.url, required this.bytes, required this.crc32, required this.sha256});

  final Uri url;
  final int bytes;
  final String crc32;
  final String sha256;
}

@immutable
final class SourceCollectionPlugin {
  const SourceCollectionPlugin({
    required this.id,
    required this.name,
    required this.version,
    required this.format,
    required this.byteLength,
    required this.checksum,
    required this.openBytes,
  });

  final String id;
  final String name;
  final String version;
  final String format;
  final int byteLength;
  final String checksum;
  final Stream<List<int>> Function() openBytes;

  PluginTransferArtifact get artifact => PluginTransferArtifact(
    engine: PluginEngine.node,
    bytes: byteLength,
    checksum: checksum,
    pluginId: id,
    version: version,
    format: format == 'singleFile' ? PluginArtifactFormat.singleFile : PluginArtifactFormat.archive,
    provenance: PluginArtifactProvenance.installed,
    developmentFingerprint: null,
    developmentRevision: null,
  );
}

@immutable
final class SourceCollection {
  const SourceCollection(this.plugins);

  final List<SourceCollectionPlugin> plugins;
}

final class SourceCollectionImportException implements Exception {
  const SourceCollectionImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

SourceCollection parseSourceCollection(List<int> input) {
  if (input.isEmpty || input.length > sourceCollectionMaxArchiveBytes) {
    throw const SourceCollectionImportException('合集压缩包为空或超过 512 MiB。');
  }

  final directory = ZipDirectory();
  try {
    directory.read(InputMemoryStream(input));
  } on Object {
    throw const SourceCollectionImportException('合集不是有效的 ZIP 文件。');
  }
  final headers = directory.fileHeaders;
  if (headers.length < 2 || headers.length > sourceCollectionMaxPlugins + 2) {
    throw const SourceCollectionImportException('合集必须包含 1 至 256 个数据源文件。');
  }

  final names = <String>{};
  var totalUncompressedBytes = 0;
  for (final header in headers) {
    final name = header.filename;
    if (!names.add(name) || name.contains('\\') || name.startsWith('/') || name.contains('../') || name.contains('/..')) {
      throw const SourceCollectionImportException('合集包含重复或不安全的 ZIP 路径。');
    }
    final mode = header.externalFileAttributes >> 16;
    if ((mode & 0xf000) == 0xa000) {
      throw const SourceCollectionImportException('合集不允许包含符号链接。');
    }
    final size = header.uncompressedSize;
    if (size < 0) throw const SourceCollectionImportException('合集包含无效的文件大小。');
    if (name.endsWith('/')) {
      if (name != 'plugins/' || size != 0) {
        throw const SourceCollectionImportException('合集包含未声明的目录项。');
      }
      continue;
    }
    totalUncompressedBytes += size;
    if (name == 'manifest.json') {
      if (size <= 0 || size > sourceCollectionMaxManifestBytes) {
        throw const SourceCollectionImportException('合集清单超过 1 MiB。');
      }
    } else if (size <= 0 || size > maxPluginTransferBytes) {
      throw const SourceCollectionImportException('单个数据源文件必须大于 0 且不超过 32 MiB。');
    }
    if (totalUncompressedBytes > maxPluginTransferBatchBytes + sourceCollectionMaxManifestBytes) {
      throw const SourceCollectionImportException('合集解压后超过 512 MiB。');
    }
  }
  if (!names.contains('manifest.json')) {
    throw const SourceCollectionImportException('合集缺少 manifest.json。');
  }

  final decoder = ZipDecoder();
  late final Archive archive;
  try {
    archive = decoder.decodeBytes(input);
  } on Object {
    throw const SourceCollectionImportException('合集 ZIP 目录或压缩内容损坏。');
  }
  final manifestFile = archive.findFile('manifest.json');
  if (manifestFile == null || !manifestFile.isFile) {
    throw const SourceCollectionImportException('合集缺少有效的 manifest.json。');
  }
  Uint8List? manifestBytes;
  try {
    manifestBytes = manifestFile.readBytes();
  } on Object {
    throw const SourceCollectionImportException('合集清单解压失败。');
  }
  if (manifestBytes == null || manifestBytes.length > sourceCollectionMaxManifestBytes) {
    throw const SourceCollectionImportException('合集清单无法读取或超过 1 MiB。');
  }

  late final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(manifestBytes, allowMalformed: false));
  } on Object {
    throw const SourceCollectionImportException('合集清单不是有效的 UTF-8 JSON。');
  }
  manifestFile.clear();
  if (decoded is! Map<String, dynamic> ||
      decoded.keys.toSet().difference(<String>{'format', 'schemaVersion', 'plugins'}).isNotEmpty ||
      decoded['format'] != 'mgread-source-collection' ||
      decoded['schemaVersion'] != 1 ||
      decoded['plugins'] is! List<dynamic>) {
    throw const SourceCollectionImportException('合集清单格式或版本不受支持。');
  }
  final rows = decoded['plugins'] as List<dynamic>;
  if (rows.isEmpty || rows.length > sourceCollectionMaxPlugins) {
    throw const SourceCollectionImportException('合集必须包含 1 至 256 个数据源。');
  }

  final ids = <String>{};
  final expectedPaths = <String>{'manifest.json'};
  final plugins = <SourceCollectionPlugin>[];
  var totalPluginBytes = 0;
  for (final row in rows) {
    if (row is! Map<String, dynamic> ||
        row.keys.toSet().difference(<String>{'id', 'name', 'version', 'format', 'path', 'bytes', 'sha256'}).isNotEmpty) {
      throw const SourceCollectionImportException('合集清单中的数据源描述无效。');
    }
    final id = row['id'];
    final name = row['name'];
    final version = row['version'];
    final format = row['format'];
    final path = row['path'];
    final size = row['bytes'];
    final sha = row['sha256'];
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(id) ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 200 ||
        version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$').hasMatch(version) ||
        (format != 'singleFile' && format != 'archive') ||
        path is! String ||
        size is! int ||
        size <= 0 ||
        size > maxPluginTransferBytes ||
        sha is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha)) {
      throw const SourceCollectionImportException('合集清单中的数据源字段无效。');
    }
    if (!ids.add(id)) throw const SourceCollectionImportException('合集包含重复的数据源 ID。');
    final suffix = format == 'singleFile' ? '.mgplugin.js' : '.mgplugin';
    final expectedPath = 'plugins/$id-$version$suffix';
    if (path != expectedPath || !expectedPaths.add(path)) {
      throw const SourceCollectionImportException('数据源路径与 manifest 中的格式不匹配。');
    }
    final entry = archive.findFile(path);
    if (entry == null || !entry.isFile || entry.isSymbolicLink || entry.size != size) {
      throw const SourceCollectionImportException('数据源文件缺失，或文件大小与清单不符。');
    }
    Uint8List? bytes;
    try {
      bytes = entry.readBytes();
    } on Object {
      throw const SourceCollectionImportException('数据源文件解压失败。');
    }
    if (bytes == null || bytes.length != size || sha256.convert(bytes).toString() != sha) {
      throw const SourceCollectionImportException('数据源文件 SHA-256 校验失败。');
    }
    totalPluginBytes += bytes.length;
    if (totalPluginBytes > maxPluginTransferBatchBytes) {
      throw const SourceCollectionImportException('合集中的数据源总大小超过 512 MiB。');
    }
    final checksum = getCrc32(bytes).toRadixString(16).padLeft(8, '0');
    entry.clear();
    plugins.add(
      SourceCollectionPlugin(
        id: id,
        name: name.trim(),
        version: version,
        format: format,
        byteLength: bytes.length,
        checksum: checksum,
        openBytes: () => _openVerifiedEntry(input, path, size, sha),
      ),
    );
  }
  final fileNames = names.where((name) => name != 'plugins/').toSet();
  if (fileNames.length != expectedPaths.length || !fileNames.containsAll(expectedPaths)) {
    throw const SourceCollectionImportException('合集包含清单未声明的文件或缺少数据源文件。');
  }
  return SourceCollection(List<SourceCollectionPlugin>.unmodifiable(plugins));
}

Stream<List<int>> _openVerifiedEntry(List<int> archiveBytes, String path, int expectedBytes, String expectedSha256) async* {
  try {
    final archive = ZipDecoder().decodeBytes(archiveBytes);
    final file = archive.findFile(path);
    final bytes = file?.readBytes();
    if (bytes == null || bytes.length != expectedBytes || sha256.convert(bytes).toString() != expectedSha256) {
      throw const SourceCollectionImportException('导入时数据源 SHA-256 二次校验失败。');
    }
    yield bytes;
  } on SourceCollectionImportException {
    rethrow;
  } on Object {
    throw const SourceCollectionImportException('导入时数据源文件无法解压。');
  }
}

@immutable
final class SourceCollectionCandidate {
  const SourceCollectionCandidate({required this.plugin, required this.plan, this.installedName});

  final SourceCollectionPlugin plugin;
  final PluginTransferPlanItem plan;
  final String? installedName;

  bool get isInstalled => installedName != null || plan.receiverVersion != null;
  bool get canImport =>
      plan.action == PluginTransferPlanAction.missing ||
      plan.action == PluginTransferPlanAction.upgrade ||
      plan.action == PluginTransferPlanAction.same;
  bool get requiresOverwriteChoice => plan.action == PluginTransferPlanAction.upgrade || plan.action == PluginTransferPlanAction.same;
  bool get isLowerVersion => plan.action == PluginTransferPlanAction.receiverNewer;
}

List<SourceCollectionCandidate> planSourceCollection({
  required SourceCollection collection,
  required List<PluginTransferPlanItem> plan,
  required List<PluginRuntimePlugin> installed,
}) {
  if (plan.length != collection.plugins.length) {
    throw const SourceCollectionImportException('Runtime 返回的合集计划与清单不匹配。');
  }
  final byId = <String, PluginTransferPlanItem>{for (final item in plan) item.pluginId: item};
  if (byId.length != plan.length) {
    throw const SourceCollectionImportException('Runtime 返回的合集计划包含重复来源。');
  }
  final installedById = <String, PluginRuntimePlugin>{
    for (final plugin in installed)
      if (plugin.engine == 'node') plugin.id: plugin,
  };
  final candidates = <SourceCollectionCandidate>[];
  for (final plugin in collection.plugins) {
    final item = byId[plugin.id];
    if (item == null || item.version != plugin.version) {
      throw const SourceCollectionImportException('Runtime 返回的合集计划与清单不匹配。');
    }
    candidates.add(SourceCollectionCandidate(plugin: plugin, plan: item, installedName: installedById[plugin.id]?.displayName));
  }
  return List<SourceCollectionCandidate>.unmodifiable(candidates);
}

@immutable
final class SourceCollectionSelection {
  const SourceCollectionSelection({required this.artifacts, required this.forceUpgradePluginIds});

  final List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})> artifacts;
  final Set<String> forceUpgradePluginIds;
}

SourceCollectionSelection? sourceCollectionSelection(List<SourceCollectionCandidate> candidates, Set<String> selectedIds) {
  if (selectedIds.isEmpty) return null;
  final selected = candidates.where((candidate) => selectedIds.contains(candidate.plugin.id));
  if (selected.length != selectedIds.length || selected.any((candidate) => !candidate.canImport)) {
    throw const SourceCollectionImportException('选择中包含不可导入的数据源，请刷新计划后重试。');
  }
  return SourceCollectionSelection(
    artifacts: List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})>.unmodifiable(
      <({PluginTransferArtifact artifact, Stream<List<int>> bytes})>[
        for (final candidate in selected) (artifact: candidate.plugin.artifact, bytes: candidate.plugin.openBytes()),
      ],
    ),
    forceUpgradePluginIds: Set<String>.unmodifiable(<String>{
      for (final candidate in selected)
        if (candidate.requiresOverwriteChoice) candidate.plugin.id,
    }),
  );
}
