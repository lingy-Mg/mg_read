/// 书架打开时的目录自动检查编排器。
///
/// 职责：
/// - 按持久化间隔限制一次书架打开触发的全量目录检查。
/// - 复用单本刷新用例，逐本隔离失败，成功或失败后通知当前书架重新读取。
///
/// 注意：
/// - 不直接访问 Runtime 或 Content Library。
/// - 尝试与成功分别持久化；失败按退避重试，不推进成功间隔。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:mg_read/features/app_update/application/update_check_result.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/library/application/library_book_refresh_operation.dart';
import 'package:mg_read/features/library/application/library_book_refresher.dart';

final libraryCatalogRefreshCoordinatorProvider = Provider<LibraryCatalogRefreshCoordinator?>((ref) {
  final refresher = ref.read(libraryBookRefresherProvider);
  if (ref.read(appSettingsProvider).supports(AppSettingKeys.bookshelfCatalogRefreshIntervalHours) == false) {
    return null;
  }
  if (ref.read(appSettingsProvider).supports(AppSettingKeys.bookshelfCatalogLastCheckedAtMs) == false || refresher == null) {
    return null;
  }
  return LibraryCatalogRefreshCoordinator(
    settings: ref.read(appSettingsProvider),
    mayStartAutomatic: () =>
        WidgetsBinding.instance.lifecycleState == null || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
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
  LibraryCatalogRefreshCoordinator({required this.settings, required this.operation, DateTime Function()? now, this.mayStartAutomatic})
    : _now = now ?? DateTime.now;

  final bool Function()? mayStartAutomatic;
  final AppSettingsManager settings;
  final LibraryBookRefreshOperation operation;
  final DateTime Function() _now;
  Future<void>? _inFlight;
  int? _lastAttemptAtMs;
  final AutomaticCheckTiming _timing = AutomaticCheckTiming();
  bool _restored = false;
  int _manualRevision = 0;

  Future<void> maybeRefresh({required Iterable<String> bookIds, required Future<void> Function(Set<String> bookIds) onChanged}) {
    final ids = bookIds.toSet().toList(growable: false);
    if (ids.isEmpty || _inFlight != null) return _inFlight ?? Future<void>.value();

    if (mayStartAutomatic?.call() == false) return Future<void>.value();
    if (settings.supports(AppSettingKeys.bookshelfCatalogAutoRefreshEnabled) &&
        !settings.get(AppSettingKeys.bookshelfCatalogAutoRefreshEnabled)) {
      return Future<void>.value();
    }
    if (!_restored) {
      _restored = true;
      if (settings.supports(AppSettingKeys.bookshelfCatalogCheckState)) {
        _timing.restore(settings.get(AppSettingKeys.bookshelfCatalogCheckState));
      }
      final int legacy = _lastAttemptAtMs ?? settings.get(AppSettingKeys.bookshelfCatalogLastCheckedAtMs);
      if (_timing.succeededAt == null && _timing.attemptedAt == null && legacy > 0) {
        _timing.succeededAt = DateTime.fromMillisecondsSinceEpoch(legacy, isUtc: true);
      }
    }
    final now = _now().toUtc();
    if (!_timing.isDue(now, Duration(hours: settings.get(AppSettingKeys.bookshelfCatalogRefreshIntervalHours)))) {
      return Future<void>.value();
    }
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
    _restored = true;
    _manualRevision++;
    final nowMs = _now().toUtc().millisecondsSinceEpoch;
    _lastAttemptAtMs = nowMs;
    _timing.complete(_now().toUtc(), success: true);
    _persistSuccess(nowMs);
    if (settings.supports(AppSettingKeys.bookshelfCatalogCheckState)) {
      settings.set(AppSettingKeys.bookshelfCatalogCheckState, _timing.toJson()).catchError((_) {});
    }
  }

  Future<void> _run(List<String> bookIds, Future<void> Function(Set<String> bookIds) onChanged) async {
    final revision = _manualRevision;
    final report = await operation.refreshBatch(bookIds, catalogOnly: true);
    if (report.changedBookIds.isNotEmpty) await onChanged(report.changedBookIds);
    if (revision != _manualRevision) return;
    _timing.complete(_now().toUtc(), success: report.failed == 0 && report.skipped == 0);
    if (settings.supports(AppSettingKeys.bookshelfCatalogCheckState)) {
      try {
        await settings.set(AppSettingKeys.bookshelfCatalogCheckState, _timing.toJson());
      } on Object {
        /* Retain memory timing. */
      }
    }
    if (report.failed == 0 && report.skipped == 0) _persistSuccess(_now().toUtc().millisecondsSinceEpoch);
  }

  void _persistSuccess(int value) {
    settings.set(AppSettingKeys.bookshelfCatalogLastCheckedAtMs, value).catchError((_) {});
  }
}
