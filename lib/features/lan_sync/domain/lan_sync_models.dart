/// 局域网同步领域模型与有界协议常量。
///
/// 职责：
/// - 定义 HTTP 会话、manifest、插件 artifact、本地文档和导入预览类型。
/// - 校验跨设备 JSON 的字段、枚举和大小上限。
///
/// 注意：
/// - artifact 字节保持原格式传输，不在领域层转换 ZIP。
/// - 领域模型不暴露 Runtime 路径或传输 token。
///
library;

import 'package:flutter/foundation.dart';

import 'package:mg_read/core/content_library/content_library.dart';

const int lanSyncProtocolVersion = 3;
const int lanSyncMaxManifestBytes = 1024 * 1024;
const int lanSyncMaxPluginBytes = 32 * 1024 * 1024;
const int lanSyncMaxLocalDocumentBytes = 256 * 1024 * 1024;
const int lanSyncMaxLocalCoverBytes = 8 * 1024 * 1024;
const int lanSyncMaxLocalDocumentCount = 1000;
const int lanSyncMaxShelfItemCount = bookshelfMaxItemCount;
const int lanSyncMaxBatchBytes = 512 * 1024 * 1024;
const Duration lanSyncSessionLifetime = Duration(minutes: 10);
const Duration lanSyncHandshakeTimeout = Duration(seconds: 30);

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

enum LanSyncPluginPlanState { developmentConflict, missing, upgrade, sameVersion, receiverNewer, unavailable }

enum LanSyncPluginArtifactFormat { singleFile, archive }

enum LanSyncPluginProvenance { installed, development, developmentReplica }

enum LanSyncPluginEngine { node, native }

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
final class LanSyncLocalDocumentConflict {
  const LanSyncLocalDocumentConflict({
    required this.documentId,
    required this.senderTitle,
    required this.localTitle,
    this.choice = LanSyncConflictChoice.keepLocal,
  });
  final String documentId, senderTitle, localTitle;
  final LanSyncConflictChoice choice;
  LanSyncLocalDocumentConflict withChoice(LanSyncConflictChoice value) =>
      LanSyncLocalDocumentConflict(documentId: documentId, senderTitle: senderTitle, localTitle: localTitle, choice: value);
}

@immutable
final class LanSyncImportPreview {
  LanSyncImportPreview({
    required this.newItemCount,
    required this.conflicts,
    required this.blockedItemCount,
    required this.pluginPlans,
    List<LanSyncLocalDocumentConflict> localDocumentConflicts = const <LanSyncLocalDocumentConflict>[],
    Set<String> selectedPluginIds = const <String>{},
    Set<String> selectedShelfItemIds = const <String>{},
    Set<String> selectedLocalDocumentIds = const <String>{},
    Set<String> forceUpgradePluginIds = const <String>{},
  }) : localDocumentConflicts = List<LanSyncLocalDocumentConflict>.unmodifiable(localDocumentConflicts),
       selectedPluginIds = Set<String>.unmodifiable(selectedPluginIds),
       selectedShelfItemIds = Set<String>.unmodifiable(selectedShelfItemIds),
       selectedLocalDocumentIds = Set<String>.unmodifiable(selectedLocalDocumentIds),
       forceUpgradePluginIds = Set<String>.unmodifiable(forceUpgradePluginIds);

  final int newItemCount;
  final List<LanSyncBookConflict> conflicts;
  final int blockedItemCount;
  final Map<String, LanSyncPluginPlanState> pluginPlans;
  final List<LanSyncLocalDocumentConflict> localDocumentConflicts;
  final Set<String> selectedPluginIds;
  final Set<String> selectedShelfItemIds;
  final Set<String> selectedLocalDocumentIds;

  /// Plugin IDs selected for an explicit sender-to-receiver replacement.
  final Set<String> forceUpgradePluginIds;

  Set<String> get recommendedPluginIds => <String>{
    for (final entry in pluginPlans.entries)
      if (entry.value == LanSyncPluginPlanState.missing || entry.value == LanSyncPluginPlanState.upgrade) entry.key,
  };

  bool get hasSelection => selectedPluginIds.isNotEmpty || selectedShelfItemIds.isNotEmpty || selectedLocalDocumentIds.isNotEmpty;

  LanSyncImportPreview withSelection({
    Set<String>? pluginIds,
    Set<String>? shelfItemIds,
    Set<String>? localDocumentIds,
    Set<String>? forceUpgradeIds,
  }) => LanSyncImportPreview(
    newItemCount: newItemCount,
    conflicts: conflicts,
    blockedItemCount: blockedItemCount,
    pluginPlans: pluginPlans,
    localDocumentConflicts: localDocumentConflicts,
    selectedPluginIds: pluginIds ?? selectedPluginIds,
    selectedShelfItemIds: shelfItemIds ?? selectedShelfItemIds,
    selectedLocalDocumentIds: localDocumentIds ?? selectedLocalDocumentIds,
    forceUpgradePluginIds: forceUpgradeIds ?? forceUpgradePluginIds,
  );

  LanSyncImportPreview withConflictChoice(String identity, LanSyncConflictChoice choice) => LanSyncImportPreview(
    newItemCount: newItemCount,
    conflicts: <LanSyncBookConflict>[
      for (final conflict in conflicts) conflict.identity == identity ? conflict.withChoice(choice) : conflict,
    ],
    blockedItemCount: blockedItemCount,
    pluginPlans: pluginPlans,
    localDocumentConflicts: localDocumentConflicts,
    selectedPluginIds: selectedPluginIds,
    selectedShelfItemIds: selectedShelfItemIds,
    selectedLocalDocumentIds: selectedLocalDocumentIds,
    forceUpgradePluginIds: forceUpgradePluginIds,
  );

  LanSyncImportPreview withLocalDocumentChoice(String documentId, LanSyncConflictChoice choice) => LanSyncImportPreview(
    newItemCount: newItemCount,
    conflicts: conflicts,
    blockedItemCount: blockedItemCount,
    pluginPlans: pluginPlans,
    localDocumentConflicts: <LanSyncLocalDocumentConflict>[
      for (final conflict in localDocumentConflicts) conflict.documentId == documentId ? conflict.withChoice(choice) : conflict,
    ],
    selectedPluginIds: selectedPluginIds,
    selectedShelfItemIds: selectedShelfItemIds,
    selectedLocalDocumentIds: selectedLocalDocumentIds,
    forceUpgradePluginIds: forceUpgradePluginIds,
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
    this.localDocumentsImported = 0,
  });

  final int added;
  final int updated;
  final int keptLocal;
  final int blocked;
  final int pluginInstalled;
  final int pluginSkipped;
  final int pluginFailed;
  final int localDocumentsImported;
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
    required this.checksum,
    required this.transferable,
    this.deferred = false,
    this.developmentFingerprint,
    this.developmentRevision,
    this.displayName,
    this.provenance = LanSyncPluginProvenance.installed,
    this.engine = LanSyncPluginEngine.node,
    this.reason,
  });

  final String id;
  final String version;
  final int bytes;
  final LanSyncPluginArtifactFormat artifactFormat;
  final String? developmentFingerprint;
  final int? developmentRevision;
  final String checksum;
  final bool transferable;
  final bool deferred;
  final String? displayName;
  final LanSyncPluginProvenance provenance;
  final LanSyncPluginEngine engine;
  final String? reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'version': version,
    'bytes': bytes,
    'developmentFingerprint': developmentFingerprint,
    'developmentRevision': developmentRevision,
    'artifactFormat': artifactFormat.name,
    'provenance': provenance.name,
    'engine': engine.name,
    'checksum': checksum,
    'transferable': transferable,
    'deferred': deferred,
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
      developmentFingerprint: _nullableString(json, 'developmentFingerprint', maxLength: 64),
      developmentRevision: _nullableInt(json, 'developmentRevision', min: 1, max: 9007199254740991),
      checksum: _requiredString(json, 'checksum', maxLength: 16),
      transferable: _requiredBool(json, 'transferable'),
      deferred: _optionalBool(json, 'deferred') ?? false,
      displayName: _optionalString(json, 'displayName', maxLength: 512),
      provenance: switch (_requiredString(json, 'provenance', maxLength: 32)) {
        'installed' => LanSyncPluginProvenance.installed,
        'development' => LanSyncPluginProvenance.development,
        'developmentReplica' => LanSyncPluginProvenance.developmentReplica,
        _ => throw const FormatException('invalid_plugin_provenance'),
      },
      engine: switch (_optionalString(json, 'engine', maxLength: 16)) {
        null || 'node' => LanSyncPluginEngine.node,
        'native' => LanSyncPluginEngine.native,
        _ => throw const FormatException('invalid_plugin_engine'),
      },
      reason: _optionalString(json, 'reason', maxLength: 128),
    );
    if (!RegExp(r'^[a-f0-9]{8}$').hasMatch(descriptor.checksum) ||
        (descriptor.transferable && descriptor.bytes == 0 && !descriptor.deferred) ||
        (descriptor.deferred && (!descriptor.transferable || descriptor.bytes != 0)) ||
        (descriptor.deferred && descriptor.checksum != ''.padLeft(8, '0')) ||
        (!descriptor.transferable && descriptor.bytes != 0) ||
        (descriptor.provenance == LanSyncPluginProvenance.installed &&
            (descriptor.developmentFingerprint != null || descriptor.developmentRevision != null)) ||
        (descriptor.engine == LanSyncPluginEngine.native &&
            (descriptor.artifactFormat != LanSyncPluginArtifactFormat.archive ||
                descriptor.provenance != LanSyncPluginProvenance.installed)) ||
        (descriptor.provenance != LanSyncPluginProvenance.installed &&
            (descriptor.developmentFingerprint == null ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(descriptor.developmentFingerprint!) ||
                descriptor.developmentRevision == null))) {
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

/// A semantic local-bookmark payload. Item IDs are receiver-local and never
/// cross the wire; the receiving Content Library remaps anchors on commit.
@immutable
final class LanSyncLocalBookmark {
  const LanSyncLocalBookmark({
    required this.id,
    required this.chapterId,
    required this.paragraphId,
    required this.characterOffset,
    required this.chapterTitle,
    required this.excerpt,
    required this.createdAtUtc,
  });

  final String id, chapterId, paragraphId, chapterTitle, excerpt;
  final int characterOffset;
  final DateTime createdAtUtc;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'chapterId': chapterId,
    'paragraphId': paragraphId,
    'characterOffset': characterOffset,
    'chapterTitle': chapterTitle,
    'excerpt': excerpt,
    'createdAtUtc': createdAtUtc.toUtc().toIso8601String(),
  };

  factory LanSyncLocalBookmark.fromJson(Map<String, Object?> json) {
    final createdAt = DateTime.tryParse(_requiredString(json, 'createdAtUtc', maxLength: 64));
    if (createdAt == null) throw const FormatException('invalid_bookmark_date');
    return LanSyncLocalBookmark(
      id: _requiredString(json, 'id', maxLength: 256),
      chapterId: _requiredString(json, 'chapterId', maxLength: 2048),
      paragraphId: _requiredString(json, 'paragraphId', maxLength: 2048),
      characterOffset: _requiredInt(json, 'characterOffset', min: 0, max: 10000000),
      chapterTitle: _requiredString(json, 'chapterTitle', maxLength: 4096),
      excerpt: _requiredString(json, 'excerpt', maxLength: 8192),
      createdAtUtc: createdAt.toUtc(),
    );
  }
}

enum LanSyncLocalReadingKind { text, comic }

@immutable
final class LanSyncLocalMangaProgress {
  const LanSyncLocalMangaProgress({
    required this.chapterId,
    required this.imageId,
    required this.imageFraction,
    required this.chapterIndex,
    required this.bookFraction,
    required this.updatedAtUtc,
    required this.readingSeconds,
  });

  final String chapterId, imageId;
  final double imageFraction, bookFraction;
  final int chapterIndex, readingSeconds;
  final DateTime updatedAtUtc;

  Map<String, Object?> toJson() => <String, Object?>{
    'chapterId': chapterId,
    'imageId': imageId,
    'imageFraction': imageFraction,
    'chapterIndex': chapterIndex,
    'bookFraction': bookFraction,
    'updatedAtUtc': updatedAtUtc.toUtc().toIso8601String(),
    'readingSeconds': readingSeconds,
  };

  factory LanSyncLocalMangaProgress.fromJson(Map<String, Object?> json) {
    final updatedAt = DateTime.tryParse(_requiredString(json, 'updatedAtUtc', maxLength: 64));
    if (updatedAt == null) throw const FormatException('invalid_updated_at');
    return LanSyncLocalMangaProgress(
      chapterId: _requiredString(json, 'chapterId', maxLength: 2048),
      imageId: _requiredString(json, 'imageId', maxLength: 2048),
      imageFraction: _requiredFraction(json, 'imageFraction'),
      chapterIndex: _requiredInt(json, 'chapterIndex', min: 0, max: 10000000),
      bookFraction: _requiredFraction(json, 'bookFraction'),
      updatedAtUtc: updatedAt.toUtc(),
      readingSeconds: _requiredInt(json, 'readingSeconds', min: 0, max: 1576800000),
    );
  }
}

@immutable
final class LanSyncLocalMangaBookmark {
  const LanSyncLocalMangaBookmark({
    required this.id,
    required this.chapterId,
    required this.imageId,
    required this.imageFraction,
    required this.createdAtUtc,
  });

  final String id, chapterId, imageId;
  final double imageFraction;
  final DateTime createdAtUtc;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'chapterId': chapterId,
    'imageId': imageId,
    'imageFraction': imageFraction,
    'createdAtUtc': createdAtUtc.toUtc().toIso8601String(),
  };

  factory LanSyncLocalMangaBookmark.fromJson(Map<String, Object?> json) {
    final createdAt = DateTime.tryParse(_requiredString(json, 'createdAtUtc', maxLength: 64));
    if (createdAt == null) throw const FormatException('invalid_bookmark_date');
    return LanSyncLocalMangaBookmark(
      id: _requiredString(json, 'id', maxLength: 256),
      chapterId: _requiredString(json, 'chapterId', maxLength: 2048),
      imageId: _requiredString(json, 'imageId', maxLength: 2048),
      imageFraction: _requiredFraction(json, 'imageFraction'),
      createdAtUtc: createdAt.toUtc(),
    );
  }
}

/// Path-free offer for one imported TXT/EPUB original and its reading state.
@immutable
final class LanSyncLocalDocumentDescriptor {
  LanSyncLocalDocumentDescriptor({
    required this.documentId,
    required this.rawSha256,
    required this.originalBytes,
    required this.format,
    required this.title,
    required Map<String, Object?> options,
    this.author,
    this.progress,
    this.readingKind,
    this.mangaProgress,
    List<LanSyncLocalMangaBookmark> mangaBookmarks = const <LanSyncLocalMangaBookmark>[],
    this.coverSha256,
    this.coverBytes,
    this.coverMimeType,
    List<LanSyncLocalBookmark> bookmarks = const <LanSyncLocalBookmark>[],
  }) : bookmarks = List<LanSyncLocalBookmark>.unmodifiable(bookmarks),
       mangaBookmarks = List<LanSyncLocalMangaBookmark>.unmodifiable(mangaBookmarks),
       options = Map<String, Object?>.unmodifiable(options);

  final String documentId, rawSha256, format, title;
  final int originalBytes;
  final String? author;
  final String? coverSha256, coverMimeType;
  final int? coverBytes;
  final Map<String, Object?> options;
  final LanSyncReadingProgress? progress;
  final List<LanSyncLocalBookmark> bookmarks;
  final LanSyncLocalReadingKind? readingKind;
  final LanSyncLocalMangaProgress? mangaProgress;
  final List<LanSyncLocalMangaBookmark> mangaBookmarks;

  Map<String, Object?> toJson() => <String, Object?>{
    'documentId': documentId,
    'rawSha256': rawSha256,
    'originalBytes': originalBytes,
    'format': format,
    'title': title,
    if (author != null) 'author': author,
    if (readingKind != null) 'readingKind': readingKind!.name,
    if (coverSha256 != null) 'coverSha256': coverSha256,
    if (coverBytes != null) 'coverBytes': coverBytes,
    if (coverMimeType != null) 'coverMimeType': coverMimeType,
    'options': options,
    if (progress != null) 'progress': progress!.toJson(),
    'bookmarks': <Object?>[for (final bookmark in bookmarks) bookmark.toJson()],
    if (mangaProgress != null) 'mangaProgress': mangaProgress!.toJson(),
    if (mangaBookmarks.isNotEmpty) 'mangaBookmarks': <Object?>[for (final bookmark in mangaBookmarks) bookmark.toJson()],
  };

  factory LanSyncLocalDocumentDescriptor.fromJson(Map<String, Object?> json) {
    final format = _requiredString(json, 'format', maxLength: 8);
    if (format != 'txt' && format != 'epub') throw const FormatException('invalid_local_document');
    final hash = _requiredString(json, 'rawSha256', maxLength: 64);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) throw const FormatException('invalid_local_document');
    final rawOptions = _requiredMap(json['options']);
    if (rawOptions.length > 16) throw const FormatException('invalid_local_document');
    final rawBookmarks = json['bookmarks'] ?? const <Object?>[];
    if (rawBookmarks is! List || rawBookmarks.length > 10000) throw const FormatException('invalid_local_document');
    final rawProgress = json['progress'];
    final rawMangaProgress = json['mangaProgress'];
    final rawMangaBookmarks = json['mangaBookmarks'] ?? const <Object?>[];
    if (rawMangaBookmarks is! List || rawMangaBookmarks.length > 10000) throw const FormatException('invalid_local_document');
    final rawReadingKind = json['readingKind'];
    final readingKind = _parseLanSyncLocalReadingKind(rawReadingKind);
    if (rawReadingKind != null && readingKind == null) throw const FormatException('invalid_local_document');
    if ((readingKind == LanSyncLocalReadingKind.comic && (rawProgress != null || rawBookmarks.isNotEmpty)) ||
        (readingKind != LanSyncLocalReadingKind.comic && (rawMangaProgress != null || rawMangaBookmarks.isNotEmpty))) {
      throw const FormatException('invalid_local_document');
    }
    final originalBytes = _requiredInt(json, 'originalBytes', min: 1, max: lanSyncMaxLocalDocumentBytes);
    final coverSha256 = _optionalString(json, 'coverSha256', maxLength: 64);
    final coverBytes = json.containsKey('coverBytes') ? _requiredInt(json, 'coverBytes', min: 1, max: lanSyncMaxLocalCoverBytes) : null;
    final coverMimeType = _optionalString(json, 'coverMimeType', maxLength: 64);
    if ((coverSha256 == null) != (coverBytes == null) ||
        (coverSha256 == null) != (coverMimeType == null) ||
        (coverSha256 != null && !RegExp(r'^[0-9a-f]{64}$').hasMatch(coverSha256)) ||
        (coverMimeType != null && !const <String>{'image/png', 'image/jpeg', 'image/webp', 'image/gif'}.contains(coverMimeType))) {
      throw const FormatException('invalid_local_cover');
    }
    return LanSyncLocalDocumentDescriptor(
      documentId: _requiredString(json, 'documentId', maxLength: 128),
      rawSha256: hash,
      originalBytes: originalBytes,
      format: format,
      title: _requiredString(json, 'title', maxLength: 1024),
      author: _optionalString(json, 'author', maxLength: 1024),
      coverSha256: coverSha256,
      coverBytes: coverBytes,
      coverMimeType: coverMimeType,
      options: Map<String, Object?>.from(rawOptions),
      progress: rawProgress == null ? null : LanSyncReadingProgress.fromJson(_requiredMap(rawProgress)),
      bookmarks: <LanSyncLocalBookmark>[for (final raw in rawBookmarks) LanSyncLocalBookmark.fromJson(_requiredMap(raw))],
      readingKind: readingKind,
      mangaProgress: rawMangaProgress == null ? null : LanSyncLocalMangaProgress.fromJson(_requiredMap(rawMangaProgress)),
      mangaBookmarks: <LanSyncLocalMangaBookmark>[
        for (final raw in rawMangaBookmarks) LanSyncLocalMangaBookmark.fromJson(_requiredMap(raw)),
      ],
    );
  }
}

LanSyncLocalReadingKind? _parseLanSyncLocalReadingKind(Object? value) {
  if (value == null) return null;
  for (final kind in LanSyncLocalReadingKind.values) {
    if (kind.name == value) return kind;
  }
  return null;
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
    this.coverOrientation = 'portrait',
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
  final String coverOrientation;
  final String? sourceName;
  final LanSyncReadingProgress? progress;

  String get identity => '$pluginId\u001f$remoteContentId';

  LanSyncShelfItem withProgress(LanSyncReadingProgress? value) => LanSyncShelfItem(
    pluginId: pluginId,
    pluginVersion: pluginVersion,
    remoteContentId: remoteContentId,
    contentKind: contentKind,
    title: title,
    author: author,
    coverUrl: coverUrl,
    coverOrientation: coverOrientation,
    sourceName: sourceName,
    progress: value,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'pluginId': pluginId,
    'pluginVersion': pluginVersion,
    'remoteContentId': remoteContentId,
    'contentKind': contentKind,
    'title': title,
    if (author != null) 'author': author,
    if (coverUrl != null) 'coverUrl': coverUrl,
    'coverOrientation': coverOrientation,
    if (sourceName != null) 'sourceName': sourceName,
    if (progress != null) 'progress': progress!.toJson(),
  };

  factory LanSyncShelfItem.fromJson(Map<String, Object?> json) {
    final kind = _requiredString(json, 'contentKind', maxLength: 16);
    if (kind != 'novel' && kind != 'manga') {
      throw const FormatException('invalid_content_kind');
    }
    final rawProgress = json['progress'];
    final coverOrientation = _optionalString(json, 'coverOrientation', maxLength: 16) ?? 'portrait';
    if (coverOrientation != 'portrait' && coverOrientation != 'square' && coverOrientation != 'landscape') {
      throw const FormatException('invalid_cover_orientation');
    }
    return LanSyncShelfItem(
      pluginId: _requiredString(json, 'pluginId', maxLength: 256),
      pluginVersion: _requiredString(json, 'pluginVersion', maxLength: 128),
      remoteContentId: _requiredString(json, 'remoteContentId', maxLength: 2048),
      contentKind: kind,
      title: _requiredString(json, 'title', maxLength: 4096),
      author: _optionalString(json, 'author', maxLength: 2048),
      coverUrl: _optionalString(json, 'coverUrl', maxLength: 8192),
      coverOrientation: coverOrientation,
      sourceName: _optionalString(json, 'sourceName', maxLength: 512),
      progress: rawProgress == null ? null : LanSyncReadingProgress.fromJson(_requiredMap(rawProgress)),
    );
  }
}

@immutable
final class LanSyncManifest {
  const LanSyncManifest({
    required this.plugins,
    required this.shelfItems,
    required this.skippedShelfItems,
    this.localDocuments = const <LanSyncLocalDocumentDescriptor>[],
  });

  final List<LanSyncPluginDescriptor> plugins;
  final List<LanSyncShelfItem> shelfItems;
  final int skippedShelfItems;
  final List<LanSyncLocalDocumentDescriptor> localDocuments;

  LanSyncManifest selectShelfItems(Set<String> selectedIdentities, {Set<String>? selectedLocalDocumentIds}) => LanSyncManifest(
    plugins: plugins,
    shelfItems: <LanSyncShelfItem>[
      for (final item in shelfItems)
        if (selectedIdentities.contains(item.identity)) item,
    ],
    skippedShelfItems: skippedShelfItems,
    localDocuments: <LanSyncLocalDocumentDescriptor>[
      for (final document in localDocuments)
        if (selectedLocalDocumentIds?.contains(document.documentId) ?? false) document,
    ],
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 3,
    'plugins': <Object?>[for (final plugin in plugins) plugin.toJson()],
    'shelfItems': <Object?>[for (final item in shelfItems) item.toJson()],
    'skippedShelfItems': skippedShelfItems,
    'localDocuments': <Object?>[for (final document in localDocuments) document.toJson()],
  };

  /// Paired HTTP sessions keep the small bookshelf-metadata and progress tasks
  /// separate. Plugin descriptors are task offers; each selected artifact is
  /// transferred independently by the transport.
  Map<String, Object?> toPairedTasksJson() => <String, Object?>{
    'schemaVersion': 4,
    'plugins': <Object?>[for (final plugin in plugins) plugin.toJson()],
    'bookshelf': <String, Object?>{
      'items': <Object?>[for (final item in shelfItems) item.withProgress(null).toJson()],
      'skippedItems': skippedShelfItems,
    },
    'progress': <Object?>[
      for (final item in shelfItems)
        if (item.progress case final progress?)
          <String, Object?>{'pluginId': item.pluginId, 'remoteContentId': item.remoteContentId, 'value': progress.toJson()},
    ],
    'localDocuments': <Object?>[for (final document in localDocuments) document.toJson()],
  };

  factory LanSyncManifest.fromPairedTasksJson(Map<String, Object?> json) {
    final schemaVersion = json['schemaVersion'];
    if (schemaVersion != 3 && schemaVersion != 4) throw const FormatException('unsupported_manifest');
    final rawBookshelf = _requiredMap(json['bookshelf']);
    final rawItems = _requiredList(rawBookshelf['items']);
    final rawProgress = _requiredList(json['progress']);
    if (rawItems.length > lanSyncMaxShelfItemCount || rawProgress.length > lanSyncMaxShelfItemCount) {
      throw const FormatException('manifest_limit_exceeded');
    }
    final metadata = <LanSyncShelfItem>[for (final raw in rawItems) LanSyncShelfItem.fromJson(_requiredMap(raw))];
    final metadataByIdentity = <String, LanSyncShelfItem>{for (final item in metadata) item.identity: item};
    if (metadata.any((item) => item.progress != null) || metadataByIdentity.length != metadata.length) {
      throw const FormatException('invalid_bookshelf_task');
    }
    final progressByIdentity = <String, LanSyncReadingProgress>{};
    for (final raw in rawProgress) {
      final value = _requiredMap(raw);
      final pluginId = _requiredString(value, 'pluginId', maxLength: 256);
      final remoteContentId = _requiredString(value, 'remoteContentId', maxLength: 2048);
      final identity = '$pluginId\u001f$remoteContentId';
      if (!metadataByIdentity.containsKey(identity) || progressByIdentity.containsKey(identity)) {
        throw const FormatException('invalid_progress_task');
      }
      progressByIdentity[identity] = LanSyncReadingProgress.fromJson(_requiredMap(value['value']));
    }
    final rawLocalDocuments = schemaVersion == 4 ? _requiredList(json['localDocuments']) : const <Object?>[];
    return LanSyncManifest.fromJson(<String, Object?>{
      'schemaVersion': 3,
      'plugins': _requiredList(json['plugins']),
      'shelfItems': <Object?>[for (final item in metadata) item.withProgress(progressByIdentity[item.identity]).toJson()],
      'skippedShelfItems': _requiredInt(rawBookshelf, 'skippedItems', min: 0, max: lanSyncMaxShelfItemCount),
      'localDocuments': rawLocalDocuments,
    });
  }

  factory LanSyncManifest.fromJson(Map<String, Object?> json) {
    final schemaVersion = json['schemaVersion'];
    if (schemaVersion != 2 && schemaVersion != 3) {
      throw const FormatException('unsupported_manifest');
    }
    final rawPlugins = _requiredList(json['plugins']);
    final rawItems = _requiredList(json['shelfItems']);
    if (rawItems.length > lanSyncMaxShelfItemCount) {
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
    final rawLocalDocuments = schemaVersion == 3 ? _requiredList(json['localDocuments']) : const <Object?>[];
    if (rawLocalDocuments.length > lanSyncMaxLocalDocumentCount) throw const FormatException('manifest_limit_exceeded');
    final localDocuments = <LanSyncLocalDocumentDescriptor>[
      for (final raw in rawLocalDocuments) LanSyncLocalDocumentDescriptor.fromJson(_requiredMap(raw)),
    ];
    final totalLocalBytes = localDocuments.fold<int>(0, (sum, document) => sum + document.originalBytes + (document.coverBytes ?? 0));
    if (totalLocalBytes + totalBytes > lanSyncMaxBatchBytes ||
        localDocuments.map((document) => document.documentId).toSet().length != localDocuments.length) {
      throw const FormatException('manifest_limit_exceeded');
    }
    return LanSyncManifest(
      plugins: List.unmodifiable(plugins),
      shelfItems: List.unmodifiable(<LanSyncShelfItem>[for (final raw in rawItems) LanSyncShelfItem.fromJson(_requiredMap(raw))]),
      skippedShelfItems: _requiredInt(json, 'skippedShelfItems', min: 0, max: lanSyncMaxShelfItemCount),
      localDocuments: List<LanSyncLocalDocumentDescriptor>.unmodifiable(localDocuments),
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

String? _nullableString(Map<String, Object?> json, String key, {required int maxLength}) {
  if (!json.containsKey(key)) throw FormatException('invalid_$key');
  return _optionalString(json, key, maxLength: maxLength);
}

int _requiredInt(Map<String, Object?> json, String key, {int? min, int? max}) {
  final value = json[key];
  if (value is! int || (min != null && value < min) || (max != null && value > max)) {
    throw FormatException('invalid_$key');
  }
  return value;
}

int? _nullableInt(Map<String, Object?> json, String key, {int? min, int? max}) {
  if (!json.containsKey(key)) throw FormatException('invalid_$key');
  final value = json[key];
  if (value == null) return null;
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

bool? _optionalBool(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) return null;
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
