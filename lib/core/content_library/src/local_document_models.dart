/// Path-free local document import, inspection and session contracts.
library;

import 'dart:async';
import '../../local_documents/local_document_models.dart';
import 'models.dart';

export '../../local_documents/local_document_models.dart'
    show LocalDocumentFormat, LocalDocumentReadingKind, LocalDocumentParseOptions, LocalDocumentException;

enum LocalImportStatus {
  queued,
  acquiring,
  inspecting,
  awaitingConfirmation,
  parsing,
  validating,
  committing,
  succeeded,
  needsAction,
  failed,
  cancelled,
  interrupted,
}

final class LocalImportSnapshot {
  const LocalImportSnapshot({
    required this.id,
    required this.fileName,
    required this.status,
    required this.updatedAt,
    this.completedBytes = 0,
    this.totalBytes,
    this.workCompleted,
    this.workTotal,
    this.workStage,
    this.errorCode,
    this.errorDetail,
    this.itemId,
    this.title,
    this.author,
    this.format,
    this.encoding,
    this.chapterCount,
    this.wordCount,
    this.warnings = const [],
    this.isDuplicate = false,
    this.options = const LocalDocumentParseOptions(),
  });
  final String id, fileName;
  final LocalImportStatus status;
  final DateTime updatedAt;
  final int completedBytes;
  final int? workCompleted, workTotal;
  final String? workStage;
  final int? totalBytes, chapterCount, wordCount;
  final String? errorCode, errorDetail, title, author, encoding;
  final LibraryItemId? itemId;
  final LocalDocumentFormat? format;
  final List<String> warnings;
  final bool isDuplicate;
  final LocalDocumentParseOptions options;
  bool get isTerminal => [LocalImportStatus.succeeded, LocalImportStatus.failed, LocalImportStatus.cancelled].contains(status);
  Map<String, Object?> toJson() => {
    'id': id,
    'fileName': fileName,
    'status': status.name,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'completedBytes': completedBytes,
    'totalBytes': totalBytes,
    'workCompleted': workCompleted,
    'workTotal': workTotal,
    'workStage': workStage,
    'errorCode': errorCode,
    'errorDetail': errorDetail,
    'itemId': itemId?.value,
    'title': title,
    'author': author,
    'format': format?.name,
    'encoding': encoding,
    'chapterCount': chapterCount,
    'wordCount': wordCount,
    'warnings': warnings,
    'isDuplicate': isDuplicate,
    'options': options.toJson(),
  };
  factory LocalImportSnapshot.fromJson(Map<String, Object?> v) => LocalImportSnapshot(
    id: v['id']! as String,
    fileName: v['fileName']! as String,
    status: LocalImportStatus.values.byName(v['status']! as String),
    updatedAt: DateTime.parse(v['updatedAt']! as String),
    completedBytes: v['completedBytes'] as int? ?? 0,
    totalBytes: v['totalBytes'] as int?,
    workCompleted: v['workCompleted'] as int?,
    workTotal: v['workTotal'] as int?,
    workStage: v['workStage'] as String?,
    errorCode: v['errorCode'] as String?,
    errorDetail: v['errorDetail'] as String?,
    itemId: v['itemId'] is String ? LibraryItemId(v['itemId']! as String) : null,
    title: v['title'] as String?,
    author: v['author'] as String?,
    format: v['format'] is String ? LocalDocumentFormat.values.byName(v['format']! as String) : null,
    encoding: v['encoding'] as String?,
    chapterCount: v['chapterCount'] as int?,
    wordCount: v['wordCount'] as int?,
    warnings: List<String>.from(v['warnings'] as List? ?? const []),
    isDuplicate: v['isDuplicate'] == true,
    options: LocalDocumentParseOptions.fromJson(Map<String, Object?>.from(v['options'] as Map? ?? const {})),
  );
}

/// A selected file can be a native URI or desktop file. The ingress owns its
/// handle and releases it when this stream closes. It is never persisted.
final class LocalImportInput {
  const LocalImportInput({required this.fileName, required this.openRead, this.bytes, this.expectedSha256});
  final String fileName;
  final int? bytes;
  final Stream<List<int>> Function() openRead;
  final String? expectedSha256;
}

final class LocalDocumentDetails {
  const LocalDocumentDetails({
    required this.item,
    required this.documentId,
    required this.generation,
    required this.rawSha256,
    required this.originalBytes,
    required this.format,
    required this.options,
    required this.navigation,
    required this.warnings,
    required this.chapterCount,
    this.encoding,
  });
  final LibraryItem item;
  final String documentId, generation, rawSha256;
  final int originalBytes, chapterCount;
  final LocalDocumentFormat format;
  final LocalDocumentParseOptions options;
  final String? encoding;
  final List<LocalDocumentNavigation> navigation;
  final List<String> warnings;
}
