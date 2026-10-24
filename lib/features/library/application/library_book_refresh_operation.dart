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
    final changedBookIds = <String>{};
    await Future.wait<void>(
      bookIds.map((bookId) async {
        try {
          final bool changed = refresher is LibraryCatalogOnlyRefresher
              ? await (refresher as LibraryCatalogOnlyRefresher).refreshCatalogOnly(bookId)
              : refresher is LibraryBookRefreshReporter
              ? await (refresher as LibraryBookRefreshReporter).refreshAndReport(bookId)
              : await _refreshConservatively(bookId);
          if (changed) changedBookIds.add(bookId);
        } on Object {
          // Automatic checks are best-effort; the previous local catalog is
          // retained and the next scheduled opening can try again.
        }
      }),
    );
    return changedBookIds;
  }

  Future<bool> _refreshConservatively(String bookId) async {
    await refresher.refresh(bookId);
    return true;
  }
}
