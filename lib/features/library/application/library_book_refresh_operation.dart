/// 书架书籍刷新的诊断编排器。
///
/// 职责：
/// - 以一个 owner span 执行刷新，并在开发调试控制台记录完整失败上下文。
///
/// 注意：
/// - 不直接读写 Content Library；持久化仍由 LibraryBookRefresher 负责。
/// - 失败保持原书架投影，异常会原样继续交给展示层反馈。
library;

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/library/application/library_book_refresher.dart';
import 'package:mg_read/features/library/application/library_refresh_queue.dart';

enum LibraryRefreshItemStatus { success, failure, skipped }

final class LibraryRefreshItemResult {
  const LibraryRefreshItemResult(this.bookId, this.status, {this.changed = false, this.error});
  final String bookId;
  final LibraryRefreshItemStatus status;
  final bool changed;
  final Object? error;
}

final class LibraryRefreshReport {
  LibraryRefreshReport(Iterable<LibraryRefreshItemResult> items) : items = List.unmodifiable(items);
  final List<LibraryRefreshItemResult> items;
  Set<String> get changedBookIds => {
    for (final item in items)
      if (item.changed) item.bookId,
  };
  int get succeeded => items.where((item) => item.status == LibraryRefreshItemStatus.success).length;
  int get failed => items.where((item) => item.status == LibraryRefreshItemStatus.failure).length;
  int get skipped => items.where((item) => item.status == LibraryRefreshItemStatus.skipped).length;
}

/// Records one complete shelf refresh attempt.
final class LibraryBookRefreshOperation {
  LibraryBookRefreshOperation({required this.refresher, required this.diagnostics});

  final LibraryBookRefresher refresher;
  final DiagnosticsManager diagnostics;

  Future<void> refresh(String bookId) async {
    final span = diagnostics.startSpan(
      AppDiagnosticEvents.libraryOperation,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'operation': DiagnosticValue.string('bookshelfRefresh'),
        'itemCount': DiagnosticValue.int64(1),
        'resultState': DiagnosticValue.string('started'),
      }),
    );
    try {
      await refresher.refresh(bookId);
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'operation': DiagnosticValue.string('bookshelfRefresh'),
          'itemCount': DiagnosticValue.int64(1),
          'resultState': DiagnosticValue.string('committed'),
        }),
      );
    } catch (error, stackTrace) {
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'operation': DiagnosticValue.string('bookshelfRefresh'),
          'itemCount': DiagnosticValue.int64(1),
          'resultState': DiagnosticValue.string('retainedPreviousData'),
          'errorCode': DiagnosticValue.string('refresh_failed'),
          'errorText': DiagnosticValue.string(error.toString()),
          'stackTrace': DiagnosticValue.string(stackTrace.toString()),
        }),
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Refreshes every requested shelf item without allowing one source failure
  /// to prevent the remaining content types from being checked.
  Future<Set<String>> refreshAll(Iterable<String> bookIds) async {
    return (await refreshBatch(bookIds)).changedBookIds;
  }

  /// Best-effort automatic chapter checks that preserve saved book metadata.
  Future<Set<String>> refreshAllCatalogsOnly(Iterable<String> bookIds) async {
    return (await refreshBatch(bookIds, catalogOnly: true)).changedBookIds;
  }

  Future<LibraryRefreshReport> refreshBatch(Iterable<String> bookIds, {bool catalogOnly = false}) async {
    final results = <LibraryRefreshItemResult>[];
    final pending = bookIds.toSet().iterator;
    Future<void> worker() async {
      while (pending.moveNext()) {
        final bookId = pending.current;
        try {
          final bool changed = catalogOnly && refresher is LibraryCatalogOnlyRefresher
              ? await (refresher as LibraryCatalogOnlyRefresher).refreshCatalogOnly(bookId)
              : refresher is LibraryBookRefreshReporter
              ? await (refresher as LibraryBookRefreshReporter).refreshAndReport(bookId)
              : await _refreshConservatively(bookId);
          results.add(LibraryRefreshItemResult(bookId, LibraryRefreshItemStatus.success, changed: changed));
        } on LibraryRefreshSkipped {
          results.add(LibraryRefreshItemResult(bookId, LibraryRefreshItemStatus.skipped));
        } on Object catch (error) {
          results.add(LibraryRefreshItemResult(bookId, LibraryRefreshItemStatus.failure, error: error));
        }
      }
    }

    await Future.wait<void>(List.generate(4, (_) => worker()));
    return LibraryRefreshReport(results);
  }

  Future<bool> _refreshConservatively(String bookId) async {
    await refresher.refresh(bookId);
    return true;
  }
}
