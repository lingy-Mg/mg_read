/// 书架删除用例。
///
/// 职责：
/// - 编排书架条目的乐观隐藏、持久化删除与失败回滚。
/// - 为一次删除请求记录唯一的 owner span。
///
/// 注意：仅控制应用内投影；持久化仍经 LibraryBookRemover 的窄端口执行。
///
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/library/application/library_book_remover.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';

/// 一次书架删除的 application 层编排器。
final class LibraryBookRemovalOperation {
  LibraryBookRemovalOperation({required this.remover, required this.controller, required this.diagnostics});

  final LibraryBookRemover remover;
  final LibraryPageController controller;
  final DiagnosticsManager diagnostics;
  final Set<String> _inFlightBookIds = <String>{};

  /// Optimistically removes [bookId], restoring it if durable persistence fails.
  Future<void> removeBook(String bookId) async {
    if (!_inFlightBookIds.add(bookId)) return;
    final span = diagnostics.startSpan(
      AppDiagnosticEvents.libraryOperation,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'operation': DiagnosticValue.string('bookshelfDeleteIntent'),
        'itemCount': DiagnosticValue.int64(1),
        'resultState': DiagnosticValue.string('started'),
      }),
    );
    controller.beginRemoval(bookId);
    try {
      await remover.removeBook(bookId);
      controller.commitRemoval(bookId);
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'operation': DiagnosticValue.string('bookshelfDeleteIntent'),
          'itemCount': DiagnosticValue.int64(1),
          'resultState': DiagnosticValue.string('committed'),
        }),
      );
    } on Object {
      controller.rollbackRemoval(bookId);
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'operation': DiagnosticValue.string('bookshelfDeleteIntent'),
          'itemCount': DiagnosticValue.int64(1),
          'resultState': DiagnosticValue.string('rolledBack'),
          'errorCode': DiagnosticValue.string('remove_failed'),
        }),
      );
      rethrow;
    } finally {
      _inFlightBookIds.remove(bookId);
    }
  }
}

/// Shares the complete bookshelf removal lifecycle across every entrypoint.
final libraryBookRemovalOperationProvider = Provider<LibraryBookRemovalOperation?>((Ref ref) {
  final remover = ref.watch(libraryBookRemoverProvider);
  if (remover == null) return null;
  return LibraryBookRemovalOperation(
    remover: remover,
    controller: ref.read(libraryPageControllerProvider.notifier),
    diagnostics: ref.watch(diagnosticsManagerProvider),
  );
});
