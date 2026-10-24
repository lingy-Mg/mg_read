/// 书架打开时的目录自动检查编排器。
///
/// 职责：
/// - 按持久化间隔限制一次书架打开触发的全量目录检查。
/// - 复用单本刷新用例，逐本隔离失败，成功或失败后通知当前书架重新读取。
///
/// 注意：
/// - 不直接访问 Runtime 或 Content Library。
/// - “最近检查时间”按尝试记录，避免网络失败时每次重建页面都重复请求。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/library/application/library_book_refresh_operation.dart';
import 'package:mg_read/features/library/application/library_book_refresher.dart';

final libraryCatalogRefreshCoordinatorProvider = Provider<LibraryCatalogRefreshCoordinator?>((ref) {
  final refresher = ref.read(libraryBookRefresherProvider);
  if (ref.read(appSettingsProvider).supports(AppSettingKeys.bookshelfCatalogAutoRefreshEnabled) &&
      !ref.read(appSettingsProvider).get(AppSettingKeys.bookshelfCatalogAutoRefreshEnabled)) {
    return null;
  }
  if (ref.read(appSettingsProvider).supports(AppSettingKeys.bookshelfCatalogRefreshIntervalHours) == false) {
    return null;
  }
  if (ref.read(appSettingsProvider).supports(AppSettingKeys.bookshelfCatalogLastCheckedAtMs) == false || refresher == null) {
    return null;
  }
  return LibraryCatalogRefreshCoordinator(
    settings: ref.read(appSettingsProvider),
    operation: LibraryBookRefreshOperation(refresher: refresher, diagnostics: ref.read(diagnosticsManagerProvider)),
  );
});

final libraryCatalogChangeProvider = NotifierProvider<LibraryCatalogChangeController, LibraryCatalogChange>(
  LibraryCatalogChangeController.new,
);

final class LibraryCatalogChange {
  const LibraryCatalogChange({required this.revision, required this.bookIds});

  const LibraryCatalogChange.initial() : revision = 0, bookIds = const <String>{};

  final int revision;
  final Set<String> bookIds;
}

final class LibraryCatalogChangeController extends Notifier<LibraryCatalogChange> {
  @override
  LibraryCatalogChange build() => const LibraryCatalogChange.initial();

  void publish(Iterable<String> bookIds) {
    final ids = bookIds.toSet();
    if (ids.isEmpty) return;
    state = LibraryCatalogChange(revision: state.revision + 1, bookIds: Set<String>.unmodifiable(ids));
  }
}

final class LibraryCatalogRefreshCoordinator {
  LibraryCatalogRefreshCoordinator({required this.settings, required this.operation, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final AppSettingsManager settings;
  final LibraryBookRefreshOperation operation;
  final DateTime Function() _now;
  Future<void>? _inFlight;
  int? _lastAttemptAtMs;

  Future<void> maybeRefresh({required Iterable<String> bookIds, required Future<void> Function(Set<String> bookIds) onChanged}) {
    final ids = bookIds.toSet().toList(growable: false);
    if (ids.isEmpty || _inFlight != null) return _inFlight ?? Future<void>.value();

    final nowMs = _now().toUtc().millisecondsSinceEpoch;
    final int lastCheckedAtMs = _lastAttemptAtMs ?? settings.get(AppSettingKeys.bookshelfCatalogLastCheckedAtMs);
    final interval = Duration(hours: settings.get(AppSettingKeys.bookshelfCatalogRefreshIntervalHours));
    if (lastCheckedAtMs > 0 && nowMs >= lastCheckedAtMs && nowMs - lastCheckedAtMs < interval.inMilliseconds) {
      return Future<void>.value();
    }

    _lastAttemptAtMs = nowMs;
    _persistLastAttempt(nowMs);
    final task = _run(ids, onChanged);
    _inFlight = task;
    return task.whenComplete(() {
      if (identical(_inFlight, task)) _inFlight = null;
    });
  }

  /// Records a completed manual shelf refresh as the latest attempted check.
  ///
  /// Manual refreshes do not consult the interval, but the next automatic
  /// bookshelf opening should still count from this refresh instead of
  /// immediately repeating the same source requests.
  void markCheckedNow() {
    final nowMs = _now().toUtc().millisecondsSinceEpoch;
    _lastAttemptAtMs = nowMs;
    _persistLastAttempt(nowMs);
  }

  Future<void> _run(List<String> bookIds, Future<void> Function(Set<String> bookIds) onChanged) async {
    final changedBookIds = await operation.refreshAll(bookIds);
    if (changedBookIds.isNotEmpty) await onChanged(changedBookIds);
  }

  void _persistLastAttempt(int value) {
    settings.set(AppSettingKeys.bookshelfCatalogLastCheckedAtMs, value).catchError((_) {});
  }
}
