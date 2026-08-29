/// 主应用数据库缓存扫描、清理与压缩状态。
///
/// 页面只依赖窄网关和稳定统计，不接触 Content Library、SQLite 或路径。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract interface class DatabaseCacheGateway {
  Future<DatabaseCacheUsage> inspect();

  Future<DatabaseCacheCleanupResult> clearAll();

  Future<DatabaseCacheCompactionResult> compact();
}

final class EmptyDatabaseCacheGateway implements DatabaseCacheGateway {
  const EmptyDatabaseCacheGateway();

  @override
  Future<DatabaseCacheUsage> inspect() async => const DatabaseCacheUsage.empty();

  @override
  Future<DatabaseCacheCleanupResult> clearAll() async => const DatabaseCacheCleanupResult();

  @override
  Future<DatabaseCacheCompactionResult> compact() async => const DatabaseCacheCompactionResult();
}

final databaseCacheGatewayProvider = Provider<DatabaseCacheGateway>((Ref ref) => const EmptyDatabaseCacheGateway());

final databaseCacheManagementProvider = AsyncNotifierProvider.autoDispose<DatabaseCacheManagementController, DatabaseCacheManagementState>(
  DatabaseCacheManagementController.new,
);

final class DatabaseCacheManagementController extends AsyncNotifier<DatabaseCacheManagementState> {
  int _generation = 0;

  @override
  Future<DatabaseCacheManagementState> build() async {
    ref.onDispose(() => _generation++);
    return _load();
  }

  Future<void> refresh() async {
    final current = state.asData?.value;
    if (current?.isBusy == true) return;
    final generation = ++_generation;
    state = current == null
        ? const AsyncLoading<DatabaseCacheManagementState>()
        : AsyncData(current.copyWith(isRefreshing: true, clearFeedback: true));
    try {
      final value = await _load();
      if (generation == _generation) state = AsyncData(value);
    } on Object catch (error, stackTrace) {
      if (generation != _generation) return;
      state = current == null
          ? AsyncError<DatabaseCacheManagementState>(error, stackTrace)
          : AsyncData(current.copyWith(isRefreshing: false, feedback: DatabaseCacheFeedback.scanFailed));
    }
  }

  Future<void> clearAll() async {
    final current = state.asData?.value;
    if (current == null || current.isBusy) return;
    final generation = ++_generation;
    state = AsyncData(current.copyWith(isClearing: true, clearFeedback: true));
    try {
      final result = await ref.read(databaseCacheGatewayProvider).clearAll();
      final usage = await ref.read(databaseCacheGatewayProvider).inspect();
      if (generation != _generation) return;
      state = AsyncData(
        DatabaseCacheManagementState(
          usage: usage,
          releasedBytes: result.releasedLogicalBytes,
          hasCompletedCleanup: true,
          feedback: result.isPartial
              ? DatabaseCacheFeedback.partiallyCleared
              : result.deletedRecords == 0 && result.deletedContentObjects == 0
              ? DatabaseCacheFeedback.alreadyEmpty
              : DatabaseCacheFeedback.cleared,
        ),
      );
    } on Object {
      if (generation == _generation) {
        state = AsyncData(current.copyWith(isClearing: false, feedback: DatabaseCacheFeedback.clearFailed));
      }
    }
  }

  Future<void> compact() async {
    final current = state.asData?.value;
    if (current == null || current.isBusy) return;
    final generation = ++_generation;
    state = AsyncData(current.copyWith(isCompacting: true, clearFeedback: true));
    try {
      final result = await ref.read(databaseCacheGatewayProvider).compact();
      final usage = await ref.read(databaseCacheGatewayProvider).inspect();
      if (generation != _generation) return;
      state = AsyncData(
        DatabaseCacheManagementState(
          usage: usage,
          releasedBytes: result.releasedBytes,
          feedback: result.releasedBytes == 0 ? DatabaseCacheFeedback.alreadyCompact : DatabaseCacheFeedback.compacted,
        ),
      );
    } on Object {
      if (generation == _generation) {
        state = AsyncData(current.copyWith(isCompacting: false, feedback: DatabaseCacheFeedback.compactFailed));
      }
    }
  }

  Future<DatabaseCacheManagementState> _load() async =>
      DatabaseCacheManagementState(usage: await ref.read(databaseCacheGatewayProvider).inspect());
}

@immutable
final class DatabaseCacheManagementState {
  const DatabaseCacheManagementState({
    required this.usage,
    this.isRefreshing = false,
    this.isClearing = false,
    this.isCompacting = false,
    this.releasedBytes = 0,
    this.hasCompletedCleanup = false,
    this.feedback,
  });

  final DatabaseCacheUsage usage;
  final bool isRefreshing;
  final bool isClearing;
  final bool isCompacting;
  final int releasedBytes;
  final bool hasCompletedCleanup;
  final DatabaseCacheFeedback? feedback;

  bool get isBusy => isRefreshing || isClearing || isCompacting;

  DatabaseCacheManagementState copyWith({
    bool? isRefreshing,
    bool? isClearing,
    bool? isCompacting,
    DatabaseCacheFeedback? feedback,
    bool clearFeedback = false,
    bool? hasCompletedCleanup,
  }) => DatabaseCacheManagementState(
    usage: usage,
    isRefreshing: isRefreshing ?? this.isRefreshing,
    isClearing: isClearing ?? this.isClearing,
    isCompacting: isCompacting ?? this.isCompacting,
    releasedBytes: releasedBytes,
    hasCompletedCleanup: hasCompletedCleanup ?? this.hasCompletedCleanup,
    feedback: clearFeedback ? null : feedback ?? this.feedback,
  );
}

@immutable
final class DatabaseCacheUsage {
  const DatabaseCacheUsage({
    required this.staleCatalogRecords,
    required this.detachedMetadataRecords,
    required this.orphanContentObjects,
    required this.reclaimableContentBytes,
    required this.estimatedReclaimableBytes,
    required this.compactableDatabaseBytes,
  });

  const DatabaseCacheUsage.empty()
    : staleCatalogRecords = 0,
      detachedMetadataRecords = 0,
      orphanContentObjects = 0,
      reclaimableContentBytes = 0,
      estimatedReclaimableBytes = 0,
      compactableDatabaseBytes = 0;

  final int staleCatalogRecords;
  final int detachedMetadataRecords;
  final int orphanContentObjects;
  final int reclaimableContentBytes;
  final int estimatedReclaimableBytes;
  final int compactableDatabaseBytes;

  bool get isEmpty => staleCatalogRecords == 0 && detachedMetadataRecords == 0 && orphanContentObjects == 0;
}

@immutable
final class DatabaseCacheCleanupResult {
  const DatabaseCacheCleanupResult({
    this.deletedRecords = 0,
    this.deletedContentObjects = 0,
    this.releasedLogicalBytes = 0,
    this.isPartial = false,
  });

  final int deletedRecords;
  final int deletedContentObjects;
  final int releasedLogicalBytes;
  final bool isPartial;
}

@immutable
final class DatabaseCacheCompactionResult {
  const DatabaseCacheCompactionResult({this.releasedBytes = 0});

  final int releasedBytes;
}

enum DatabaseCacheFeedback { cleared, alreadyEmpty, partiallyCleared, compacted, alreadyCompact, scanFailed, clearFailed, compactFailed }
