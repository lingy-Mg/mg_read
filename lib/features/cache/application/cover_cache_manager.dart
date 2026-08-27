/// 主应用封面缓存管理状态。
///
/// 职责：
/// - 通过窄网关读取和清理可再生封面缓存。
/// - 清理持久缓存后同步失效共享的进程内封面字节。
///
/// 注意：
/// - 不管理数据源 Runtime 缓存或尚未启用的正文图片缓存。
/// - 不向页面暴露 Content Library、文件路径或持久化实现。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

abstract interface class CoverCacheGateway {
  Future<int> usageBytes();

  Future<int> clear();
}

final class EmptyCoverCacheGateway implements CoverCacheGateway {
  const EmptyCoverCacheGateway();

  @override
  Future<int> usageBytes() async => 0;

  @override
  Future<int> clear() async => 0;
}

final coverCacheGatewayProvider = Provider<CoverCacheGateway>((Ref ref) => const EmptyCoverCacheGateway());

final coverCacheManagementProvider = AsyncNotifierProvider.autoDispose<CoverCacheManagementController, CoverCacheManagementState>(
  CoverCacheManagementController.new,
);

final class CoverCacheManagementController extends AsyncNotifier<CoverCacheManagementState> {
  int _generation = 0;

  @override
  Future<CoverCacheManagementState> build() async {
    ref.onDispose(() => _generation++);
    return _load();
  }

  Future<void> refresh() async {
    final current = state.asData?.value;
    if (current?.isClearing == true || current?.isRefreshing == true) return;
    final generation = ++_generation;
    state = current == null
        ? const AsyncLoading<CoverCacheManagementState>()
        : AsyncData(current.copyWith(isRefreshing: true, clearFeedback: true));
    try {
      final value = await _load();
      if (generation == _generation) state = AsyncData(value);
    } on Object catch (error, stackTrace) {
      if (generation == _generation) {
        state = current == null
            ? AsyncError<CoverCacheManagementState>(error, stackTrace)
            : AsyncData(current.copyWith(isRefreshing: false));
      }
    }
  }

  Future<void> clear() async {
    final current = state.asData?.value;
    if (current == null || current.isClearing) return;
    final generation = ++_generation;
    state = AsyncData(current.copyWith(isClearing: true, clearFeedback: true));
    try {
      final releasedBytes = await ref.read(coverCacheGatewayProvider).clear();
      BookCoverMemoryCache.clear();
      ref.invalidate(bookCoverBytesProvider);
      if (generation == _generation) {
        state = AsyncData(
          CoverCacheManagementState(bytes: 0, feedback: releasedBytes == 0 ? CoverCacheFeedback.alreadyEmpty : CoverCacheFeedback.cleared),
        );
      }
    } on Object {
      if (generation == _generation) {
        state = AsyncData(current.copyWith(isClearing: false, feedback: CoverCacheFeedback.failure));
      }
    }
  }

  Future<CoverCacheManagementState> _load() async =>
      CoverCacheManagementState(bytes: await ref.read(coverCacheGatewayProvider).usageBytes());
}

@immutable
final class CoverCacheManagementState {
  const CoverCacheManagementState({required this.bytes, this.isClearing = false, this.isRefreshing = false, this.feedback});

  final int bytes;
  final bool isClearing;
  final bool isRefreshing;
  final CoverCacheFeedback? feedback;

  CoverCacheManagementState copyWith({bool? isClearing, bool? isRefreshing, CoverCacheFeedback? feedback, bool clearFeedback = false}) =>
      CoverCacheManagementState(
        bytes: bytes,
        isClearing: isClearing ?? this.isClearing,
        isRefreshing: isRefreshing ?? this.isRefreshing,
        feedback: clearFeedback ? null : feedback ?? this.feedback,
      );
}

enum CoverCacheFeedback { cleared, alreadyEmpty, failure }
