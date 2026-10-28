/// 书架目录自动检查的时间节流与全类型遍历测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/library/application/library_book_refresh_operation.dart';
import 'package:mg_read/features/library/application/library_book_refresher.dart';
import 'package:mg_read/features/library/application/library_catalog_refresh_coordinator.dart';

import '../../../core/diagnostics/diagnostics_testkit.dart';
import '../../../core/settings/settings_testkit.dart';

void main() {
  test('checks every content type once and skips openings inside the interval', () async {
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    await settings.initialize();
    addTearDown(settings.close);
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    final refresher = _RecordingRefresher(failingBookId: 'audio-book');
    var now = DateTime.utc(2026, 9, 14, 8);
    final coordinator = LibraryCatalogRefreshCoordinator(
      settings: settings,
      operation: LibraryBookRefreshOperation(refresher: refresher, diagnostics: diagnostics.manager),
      now: () => now,
    );
    var reloadCount = 0;

    await coordinator.maybeRefresh(
      bookIds: const <String>['novel-book', 'manga-book', 'audio-book', 'video-book', 'novel-book'],
      onChanged: (_) async => reloadCount++,
    );
    await coordinator.maybeRefresh(
      bookIds: const <String>['novel-book', 'manga-book', 'audio-book', 'video-book'],
      onChanged: (_) async => reloadCount++,
    );

    expect(refresher.bookIds, containsAllInOrder(<String>['novel-book', 'manga-book', 'audio-book', 'video-book']));
    expect(refresher.bookIds, hasLength(4));
    expect(reloadCount, 1);
    expect(settings.get(AppSettingKeys.bookshelfCatalogLastCheckedAtMs), 0);
    expect(settings.get(AppSettingKeys.bookshelfCatalogCheckState)['failures'], 1);

    now = now.add(const Duration(hours: 24, minutes: 1));
    await coordinator.maybeRefresh(bookIds: const <String>['novel-book'], onChanged: (_) async => reloadCount++);

    expect(refresher.bookIds, <String>['novel-book', 'manga-book', 'audio-book', 'video-book', 'novel-book']);
    expect(reloadCount, 2);
  });

  test('does not notify listeners when the source has no new catalog entries', () async {
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    await settings.initialize();
    addTearDown(settings.close);
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    final refresher = _NoChangeRefresher();
    final now = DateTime.utc(2026, 9, 14, 8);
    final coordinator = LibraryCatalogRefreshCoordinator(
      settings: settings,
      operation: LibraryBookRefreshOperation(refresher: refresher, diagnostics: diagnostics.manager),
      now: () => now,
    );
    var reloadCount = 0;

    await coordinator.maybeRefresh(bookIds: const <String>['novel-book'], onChanged: (_) async => reloadCount++);

    expect(refresher.catalogOnlyBookIds, <String>['novel-book']);
    expect(reloadCount, 0);
    expect(settings.get(AppSettingKeys.bookshelfCatalogLastCheckedAtMs), now.millisecondsSinceEpoch);
  });

  test('manual refresh records the check without consulting the interval', () async {
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    await settings.initialize();
    addTearDown(settings.close);
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    final refresher = _RecordingRefresher(failingBookId: 'never');
    var now = DateTime.utc(2026, 9, 14, 8);
    final coordinator = LibraryCatalogRefreshCoordinator(
      settings: settings,
      operation: LibraryBookRefreshOperation(refresher: refresher, diagnostics: diagnostics.manager),
      now: () => now,
    );

    coordinator.markCheckedNow();
    await coordinator.maybeRefresh(bookIds: const <String>['novel-book'], onChanged: (_) async {});

    expect(refresher.bookIds, isEmpty);
    expect(settings.get(AppSettingKeys.bookshelfCatalogLastCheckedAtMs), now.millisecondsSinceEpoch);
  });

  test('manual batch refresh uses full refresh while automatic batch is catalog-only', () async {
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    final refresher = _NoChangeRefresher();
    final operation = LibraryBookRefreshOperation(refresher: refresher, diagnostics: diagnostics.manager);

    await operation.refreshAll(const <String>['book']);
    await operation.refreshAllCatalogsOnly(const <String>['book']);

    expect(refresher.bookIds, <String>['book']);
    expect(refresher.catalogOnlyBookIds, <String>['book']);
  });
}

final class _RecordingRefresher implements LibraryBookRefresher {
  _RecordingRefresher({required this.failingBookId});

  final String failingBookId;
  final List<String> bookIds = <String>[];

  @override
  Future<void> refresh(String bookId) async {
    bookIds.add(bookId);
    if (bookId == failingBookId) throw StateError('source unavailable');
  }
}

final class _NoChangeRefresher implements LibraryBookRefresher, LibraryBookRefreshReporter, LibraryCatalogOnlyRefresher {
  final List<String> bookIds = <String>[];
  final List<String> catalogOnlyBookIds = <String>[];

  @override
  Future<void> refresh(String bookId) async {
    await refreshAndReport(bookId);
  }

  @override
  Future<bool> refreshAndReport(String bookId) async {
    bookIds.add(bookId);
    return false;
  }

  @override
  Future<bool> refreshCatalogOnly(String bookId) async {
    catalogOnlyBookIds.add(bookId);
    return false;
  }
}
