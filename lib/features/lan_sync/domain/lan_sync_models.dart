/// 局域网同步领域模型与有界协议常量。
///
/// 职责：
/// - 定义 v2 会话、manifest、插件 artifact 和导入预览类型。
/// - 校验跨设备 JSON 的字段、枚举和大小上限。
///
/// 注意：
/// - artifact 字节保持原格式传输，不在领域层转换 ZIP。
/// - 领域模型不暴露 Runtime 路径或传输 token。
///
/// TODO:
/// - 无。
library;

import 'package:flutter/foundation.dart';

import 'package:mg_read/core/content_library/content_library.dart';

const int lanSyncProtocolVersion = 2;
const int lanSyncMaxControlFrameBytes = 64 * 1024;
const int lanSyncMaxManifestBytes = 1024 * 1024;
const int lanSyncMaxBinaryChunkBytes = 256 * 1024;
// Keep every relay write compatible with the Android Runtime inbox bridge.
// The wire protocol may accept larger frames, but plugins are always relayed
// in this smaller bounded unit so no platform needs to re-chunk a payload.
const int lanSyncPluginRelayChunkBytes = 64 * 1024;
const int lanSyncMaxPluginBytes = 32 * 1024 * 1024;
const int lanSyncMaxPluginCount = 32;
const int lanSyncMaxShelfItemCount = bookshelfMaxItemCount;
const int lanSyncMaxBatchBytes = 512 * 1024 * 1024;
const Duration lanSyncSessionLifetime = Duration(minutes: 10);
const Duration lanSyncHandshakeTimeout = Duration(seconds: 30);
const Duration lanSyncTransferIdleTimeout = Duration(seconds: 90);
const int lanSyncDiscoveryPort = 47231;

enum LanSyncRole { sender, receiver }

enum LanSyncPhase {
  idle,
  preparing,
  discovering,
  waitingForPeer,
  pairing,
  previewing,
  transferring,
  applying,
  completed,
  failed,
  cancelled,
}

enum LanSyncConflictChoice { smartMerge, useSender, keepLocal }

enum LanSyncPluginPlanState { missing, upgrade, sameVersion, receiverNewer, unavailable }

enum LanSyncPluginArtifactFormat { singleFile, archive }

@immutable
final class LanSyncBookConflict {
  const LanSyncBookConflict({
    required this.identity,
    required this.senderTitle,
    required this.localTitle,
    this.choice = LanSyncConflictChoice.smartMerge,
  });

  final String identity;
  final String senderTitle;
  final String localTitle;
  final LanSyncConflictChoice choice;

  LanSyncBookConflict withChoice(LanSyncConflictChoice value) =>
      LanSyncBookConflict(identity: identity, senderTitle: senderTitle, localTitle: localTitle, choice: value);
}

@immutable
final class LanSyncImportPreview {
  LanSyncImportPreview({
    required this.newItemCount,
    required this.conflicts,
    required this.blockedItemCount,
    required this.pluginPlans,
    Set<String> selectedPluginIds = const <String>{},
    Set<String> selectedShelfItemIds = const <String>{},
  }) : selectedPluginIds = Set<String>.unmodifiable(selectedPluginIds),
       selectedShelfItemIds = Set<String>.unmodifiable(selectedShelfItemIds);

  final int newItemCount;
  final List<LanSyncBookConflict> conflicts;
  final int blockedItemCount;
  final Map<String, LanSyncPluginPlanState> pluginPlans;
  final Set<String> selectedPluginIds;
  final Set<String> selectedShelfItemIds;

  Set<String> get recommendedPluginIds => <String>{
    for (final entry in pluginPlans.entries)
      if (entry.value == LanSyncPluginPlanState.missing || entry.value == LanSyncPluginPlanState.upgrade) entry.key,
  };

  bool get hasSelection => selectedPluginIds.isNotEmpty || selectedShelfItemIds.isNotEmpty;

  LanSyncImportPreview withSelection({Set<String>? pluginIds, Set<String>? shelfItemIds}) => LanSyncImportPreview(
    newItemCount: newItemCount,
    conflicts: conflicts,
    blockedItemCount: blockedItemCount,
    pluginPlans: pluginPlans,
    selectedPluginIds: pluginIds ?? selectedPluginIds,
    selectedShelfItemIds: shelfItemIds ?? selectedShelfItemIds,
  );

  LanSyncImportPreview withConflictChoice(String identity, LanSyncConflictChoice choice) => LanSyncImportPreview(
    newItemCount: newItemCount,
    conflicts: <LanSyncBookConflict>[
      for (final conflict in conflicts) conflict.identity == identity ? conflict.withChoice(choice) : conflict,
    ],
    blockedItemCount: blockedItemCount,
    pluginPlans: pluginPlans,
    selectedPluginIds: selectedPluginIds,
    selectedShelfItemIds: selectedShelfItemIds,
  );
}

@immutable
final class LanSyncApplyResult {
  const LanSyncApplyResult({
    required this.added,
    required this.updated,
    required this.keptLocal,
    required this.blocked,
    required this.pluginInstalled,
    required this.pluginSkipped,
    required this.pluginFailed,
  });

  final int added;
  final int updated;
  final int keptLocal;
  final int blocked;
  final int pluginInstalled;
  final int pluginSkipped;
  final int pluginFailed;
}

@immutable
final class LanSyncPeer {
  const LanSyncPeer({required this.sessionId, required this.label, required this.address, required this.port, required this.expiresAtUtc});

  final String sessionId;
  final String label;
  final String address;
  final int port;
  final DateTime expiresAtUtc;

  String get endpoint => '$address:$port';
}

@immutable
final class LanSyncPluginDescriptor {
  const LanSyncPluginDescriptor({
    required this.id,
    required this.version,
    required this.bytes,
    required this.artifactFormat,
    required this.sha256,
    required this.transferable,
    this.displayName,
    this.reason,
  });

  final String id;
  final String version;
  final int bytes;
  final LanSyncPluginArtifactFormat artifactFormat;
  final String sha256;
  final bool transferable;
  final String? displayName;
  final String? reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'version': version,
    'bytes': bytes,
    'artifactFormat': artifactFormat.name,
    'sha256': sha256,
    'transferable': transferable,
    if (displayName != null) 'displayName': displayName,
    if (reason != null) 'reason': reason,
  };

  factory LanSyncPluginDescriptor.fromJson(Map<String, Object?> json) {
    final descriptor = LanSyncPluginDescriptor(
      id: _requiredString(json, 'id', maxLength: 256),
      version: _requiredString(json, 'version', maxLength: 128),
      bytes: _requiredInt(json, 'bytes', min: 0, max: lanSyncMaxPluginBytes),
      artifactFormat: switch (_requiredString(json, 'artifactFormat', maxLength: 32)) {
        'singleFile' => LanSyncPluginArtifactFormat.singleFile,
        'archive' => LanSyncPluginArtifactFormat.archive,
        _ => throw const FormatException('invalid_artifact_format'),
      },
      sha256: _requiredString(json, 'sha256', maxLength: 128),
      transferable: _requiredBool(json, 'transferable'),
      displayName: _optionalString(json, 'displayName', maxLength: 512),
      reason: _optionalString(json, 'reason', maxLength: 128),
    );
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(descriptor.sha256) ||
        (descriptor.transferable && descriptor.bytes == 0) ||
        (!descriptor.transferable && descriptor.bytes != 0)) {
      throw const FormatException('invalid_plugin_descriptor');
    }
    return descriptor;
  }
}

@immutable
final class LanSyncReadingProgress {
  const LanSyncReadingProgress({
    required this.chapterId,
    required this.paragraphId,
    required this.characterOffset,
    required this.chapterIndex,
    required this.chapterFraction,
    required this.bookFraction,
    required this.updatedAtUtc,
    required this.totalReadingSeconds,
  });

  final String chapterId;
  final String paragraphId;
  final int characterOffset;
  final int chapterIndex;
  final double chapterFraction;
  final double bookFraction;
  final DateTime updatedAtUtc;
  final int totalReadingSeconds;

  Map<String, Object?> toJson() => <String, Object?>{
    'chapterId': chapterId,
    'paragraphId': paragraphId,
    'characterOffset': characterOffset,
    'chapterIndex': chapterIndex,
    'chapterFraction': chapterFraction,
    'bookFraction': bookFraction,
    'updatedAtUtc': updatedAtUtc.toUtc().toIso8601String(),
    'totalReadingSeconds': totalReadingSeconds,
  };

  factory LanSyncReadingProgress.fromJson(Map<String, Object?> json) {
    final updatedAt = DateTime.tryParse(_requiredString(json, 'updatedAtUtc', maxLength: 64));
    if (updatedAt == null) throw const FormatException('invalid_updated_at');
    return LanSyncReadingProgress(
      chapterId: _requiredString(json, 'chapterId', maxLength: 2048),
      paragraphId: _requiredString(json, 'paragraphId', maxLength: 2048),
      characterOffset: _requiredInt(json, 'characterOffset', min: 0, max: 10000000),
      chapterIndex: _requiredInt(json, 'chapterIndex', min: 0, max: 10000000),
      chapterFraction: _requiredFraction(json, 'chapterFraction'),
      bookFraction: _requiredFraction(json, 'bookFraction'),
      updatedAtUtc: updatedAt.toUtc(),
      totalReadingSeconds: _requiredInt(json, 'totalReadingSeconds', min: 0, max: 1576800000),
    );
  }
}

@immutable
final class LanSyncShelfItem {
  const LanSyncShelfItem({
    required this.pluginId,
    required this.pluginVersion,
    required this.remoteContentId,
    required this.contentKind,
    required this.title,
    this.author,
    this.coverUrl,
    this.sourceName,
    this.progress,
  });

  final String pluginId;
  final String pluginVersion;
  final String remoteContentId;
  final String contentKind;
  final String title;
  final String? author;
  final String? coverUrl;
  final String? sourceName;
  final LanSyncReadingProgress? progress;

  String get identity => '$pluginId\u001f$remoteContentId';

  Map<String, Object?> toJson() => <String, Object?>{
    'pluginId': pluginId,
    'pluginVersion': pluginVersion,
    'remoteContentId': remoteContentId,
    'contentKind': contentKind,
    'title': title,
    if (author != null) 'author': author,
    if (coverUrl != null) 'coverUrl': coverUrl,
    if (sourceName != null) 'sourceName': sourceName,
    if (progress != null) 'progress': progress!.toJson(),
  };

  factory LanSyncShelfItem.fromJson(Map<String, Object?> json) {
    final kind = _requiredString(json, 'contentKind', maxLength: 16);
    if (kind != 'novel' && kind != 'manga') {
      throw const FormatException('invalid_content_kind');
    }
    final rawProgress = json['progress'];
    return LanSyncShelfItem(
      pluginId: _requiredString(json, 'pluginId', maxLength: 256),
      pluginVersion: _requiredString(json, 'pluginVersion', maxLength: 128),
      remoteContentId: _requiredString(json, 'remoteContentId', maxLength: 2048),
      contentKind: kind,
      title: _requiredString(json, 'title', maxLength: 4096),
      author: _optionalString(json, 'author', maxLength: 2048),
      coverUrl: _optionalString(json, 'coverUrl', maxLength: 8192),
      sourceName: _optionalString(json, 'sourceName', maxLength: 512),
      progress: rawProgress == null ? null : LanSyncReadingProgress.fromJson(_requiredMap(rawProgress)),
    );
  }
}

@immutable
final class LanSyncManifest {
  const LanSyncManifest({required this.plugins, required this.shelfItems, required this.skippedShelfItems});

  final List<LanSyncPluginDescriptor> plugins;
  final List<LanSyncShelfItem> shelfItems;
  final int skippedShelfItems;

  LanSyncManifest selectShelfItems(Set<String> selectedIdentities) => LanSyncManifest(
    plugins: plugins,
    shelfItems: <LanSyncShelfItem>[
      for (final item in shelfItems)
        if (selectedIdentities.contains(item.identity)) item,
    ],
    skippedShelfItems: skippedShelfItems,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 2,
    'plugins': <Object?>[for (final plugin in plugins) plugin.toJson()],
    'shelfItems': <Object?>[for (final item in shelfItems) item.toJson()],
    'skippedShelfItems': skippedShelfItems,
  };

  factory LanSyncManifest.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != 2) {
      throw const FormatException('unsupported_manifest');
    }
    final rawPlugins = _requiredList(json['plugins']);
    final rawItems = _requiredList(json['shelfItems']);
    if (rawPlugins.length > lanSyncMaxPluginCount || rawItems.length > lanSyncMaxShelfItemCount) {
      throw const FormatException('manifest_limit_exceeded');
    }
    final plugins = <LanSyncPluginDescriptor>[for (final raw in rawPlugins) LanSyncPluginDescriptor.fromJson(_requiredMap(raw))];
    if (plugins.map((plugin) => plugin.id).toSet().length != plugins.length) {
      throw const FormatException('duplicate_plugin');
    }
    final totalBytes = plugins.fold<int>(0, (sum, item) => sum + item.bytes);
    if (totalBytes > lanSyncMaxBatchBytes) {
      throw const FormatException('manifest_limit_exceeded');
    }
    return LanSyncManifest(
      plugins: List.unmodifiable(plugins),
      shelfItems: List.unmodifiable(<LanSyncShelfItem>[for (final raw in rawItems) LanSyncShelfItem.fromJson(_requiredMap(raw))]),
      skippedShelfItems: _requiredInt(json, 'skippedShelfItems', min: 0, max: lanSyncMaxShelfItemCount),
    );
  }
}

@immutable
final class LanSyncState {
  const LanSyncState({
    this.role,
    this.phase = LanSyncPhase.idle,
    this.message = '选择发送或接收开始同步',
    this.address,
    this.pairingCode,
    this.peer,
    this.manifest,
    this.transferredBytes = 0,
    this.totalBytes = 0,
    this.errorCode,
  });

  final LanSyncRole? role;
  final LanSyncPhase phase;
  final String message;
  final String? address;
  final String? pairingCode;
  final LanSyncPeer? peer;
  final LanSyncManifest? manifest;
  final int transferredBytes;
  final int totalBytes;
  final String? errorCode;

  double? get progress => totalBytes <= 0 ? null : (transferredBytes / totalBytes).clamp(0.0, 1.0);
}

Map<String, Object?> _requiredMap(Object? value) {
  if (value is! Map) throw const FormatException('expected_object');
  return value.map<String, Object?>((key, value) {
    if (key is! String) throw const FormatException('expected_string_key');
    return MapEntry(key, value);
  });
}

List<Object?> _requiredList(Object? value) {
  if (value is! List) throw const FormatException('expected_list');
  return List<Object?>.from(value);
}

String _requiredString(Map<String, Object?> json, String key, {required int maxLength}) {
  final value = json[key];
  if (value is! String || value.isEmpty || value.length > maxLength) {
    throw FormatException('invalid_$key');
  }
  return value;
}

String? _optionalString(Map<String, Object?> json, String key, {required int maxLength}) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.length > maxLength) {
    throw FormatException('invalid_$key');
  }
  return value;
}

int _requiredInt(Map<String, Object?> json, String key, {int? min, int? max}) {
  final value = json[key];
  if (value is! int || (min != null && value < min) || (max != null && value > max)) {
    throw FormatException('invalid_$key');
  }
  return value;
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('invalid_$key');
  return value;
}

double _requiredFraction(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num || !value.isFinite || value < 0 || value > 1) {
    throw FormatException('invalid_$key');
  }
  return value.toDouble();
}
