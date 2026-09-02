/// 书架页面控制器与删除用例测试。
///
/// 职责：
/// - 验证请求世代、乐观投影与删除回滚。
/// - 验证删除诊断终态不暴露用户书籍内容。
///
/// 注意：
/// - 使用受控内存 loader，不触及真实 SQLite 或文件系统。
///
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/library/application/library_overview_loader.dart';
import 'package:mg_read/features/library/application/library_book_removal_operation.dart';
import 'package:mg_read/features/library/application/library_book_refresh_operation.dart';
import 'package:mg_read/features/library/application/library_book_remover.dart';
import 'package:mg_read/features/library/application/library_book_refresher.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/application/library_page_state.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';

import '../../../core/diagnostics/diagnostics_testkit.dart';

void main() {
  test('keeps the successful overview when the page listener is replaced', () async {
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    final loader = _ControlledLibraryOverviewLoader();
    final container = ProviderContainer(
      overrides: [
        libraryOverviewLoaderProvider.overrideWithValue(loader),
        diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
      ],
    );
    addTearDown(container.dispose);

    final firstSubscription = container.listen(libraryPageControllerProvider, (_, _) {}, fireImmediately: true);
    await _flush();
    expect(loader.loadCount, 1);
    loader.completeNext(_overview('cached'));
    await _flush();
    firstSubscription.close();

    final secondSubscription = container.listen(libraryPageControllerProvider, (_, _) {}, fireImmediately: true);
    addTearDown(secondSubscription.close);
    await _flush();

    expect(loader.loadCount, 1);
    expect(container.read(libraryPageControllerProvider).overview!.items.single.title, 'cached');
  });

  test('latest request generation wins when refreshes overlap', () async {
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    final _ControlledLibraryOverviewLoader loader = _ControlledLibraryOverviewLoader();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        libraryOverviewLoaderProvider.overrideWithValue(loader),
        diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
      ],
    );
    addTearDown(container.dispose);
    final ProviderSubscription<LibraryPageState> subscription = container.listen(
      libraryPageControllerProvider,
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    await _flush();
    loader.completeNext(_overview('initial'));
    await _flush();

    final LibraryPageController controller = container.read(libraryPageControllerProvider.notifier);
    final Future<void> olderRefresh = controller.refresh();
    final Future<void> newerRefresh = controller.refresh();

    loader.completeAt(1, _overview('newer'));
    await _flush();
    loader.completeAt(0, _overview('older'));
    await Future.wait(<Future<void>>[olderRefresh, newerRefresh]);
    await _flush();

    final LibraryPageState state = container.read(libraryPageControllerProvider);
    expect(state.status, LibraryPageStatus.content);
    expect(state.overview!.items.single.title, 'newer');

    final libraryEvents = diagnostics.sink.events.where((event) => event.eventName.startsWith('library.load.')).toList(growable: false);
    final terminalEvents = libraryEvents.where((event) => event.phase == DiagnosticPhase.terminal).toList(growable: false);
    expect(
      terminalEvents.map((event) => event.outcome),
      containsAll(<DiagnosticOutcome>[DiagnosticOutcome.success, DiagnosticOutcome.cancelled]),
    );
    for (final start in libraryEvents.where((event) => event.phase == DiagnosticPhase.start)) {
      expect(terminalEvents.where((event) => event.spanId == start.spanId), hasLength(1));
    }
  });

  test('retains old data while refreshing and replaces it after completion', () async {
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    final _ControlledLibraryOverviewLoader loader = _ControlledLibraryOverviewLoader();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        libraryOverviewLoaderProvider.overrideWithValue(loader),
        diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
      ],
    );
    addTearDown(container.dispose);
    final ProviderSubscription<LibraryPageState> subscription = container.listen(
      libraryPageControllerProvider,
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    await _flush();
    loader.completeNext(_overview('old data'));
    await _flush();

    final Future<void> refresh = container.read(libraryPageControllerProvider.notifier).refresh();
    await _flush();
    final LibraryPageState refreshing = container.read(libraryPageControllerProvider);
    expect(refreshing.status, LibraryPageStatus.refreshing);
    expect(refreshing.overview!.items.single.title, 'old data');

    loader.completeNext(_overview('complete data'));
    await refresh;
    expect(container.read(libraryPageControllerProvider).overview!.items.single.title, 'complete data');
    expect(container.read(libraryPageControllerProvider).status, LibraryPageStatus.content);
  });

  test('projects shelf mutations immediately and preserves commits on refresh failure', () async {
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    final loader = _ControlledLibraryOverviewLoader();
    final container = ProviderContainer(
      overrides: [
        libraryOverviewLoaderProvider.overrideWithValue(loader),
        diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(libraryPageControllerProvider, (_, _) {}, fireImmediately: true);
    addTearDown(subscription.close);

    await _flush();
    loader.completeNext(_overview('durable'));
    await _flush();
    final controller = container.read(libraryPageControllerProvider.notifier);

    controller.beginAddition(
      mutationId: 'source:pending',
      provisionalItem: const LibraryItemSummary(id: 'pending-shelf:source:pending', title: '立即出现'),
    );
    expect(container.read(libraryPageControllerProvider).overview!.items.map((item) => item.title), contains('立即出现'));

    controller.commitAddition(
      mutationId: 'source:pending',
      durableItem: const LibraryItemSummary(id: 'book-committed', title: '立即出现'),
    );
    await _flush();
    loader.failNext(StateError('refresh unavailable'));
    await _flush();
    expect(container.read(libraryPageControllerProvider).overview!.items.map((item) => item.title), contains('立即出现'));
    expect(container.read(libraryPageControllerProvider).hasFailure, isFalse);

    controller.beginRemoval('book-durable');
    expect(container.read(libraryPageControllerProvider).overview!.items.map((item) => item.title), isNot(contains('durable')));
    controller.rollbackRemoval('book-durable');
    expect(container.read(libraryPageControllerProvider).overview!.items.map((item) => item.title), contains('durable'));
  });

  test('load failure records a stable code without exception content', () async {
    const secretCanary = 'Bearer LIBRARY-SECRET-CANARY';
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    final loader = _ControlledLibraryOverviewLoader();
    final container = ProviderContainer(
      overrides: [
        libraryOverviewLoaderProvider.overrideWithValue(loader),
        diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(libraryPageControllerProvider, (_, _) {}, fireImmediately: true);
    addTearDown(subscription.close);

    await _flush();
    loader.failNext(StateError(secretCanary));
    await _flush();

    expect(container.read(libraryPageControllerProvider).hasFailure, isTrue);
    final terminal = diagnostics.sink.events.singleWhere((event) => event.eventName == 'library.load.error');
    expect(terminal.outcome, DiagnosticOutcome.error);
    expect(jsonEncode(const DiagnosticEventCodec().encode(terminal)), isNot(contains(secretCanary)));
  });

  test('failed deletion rolls back and records an owner span', () async {
    const secretCanary = '删除书名-SECRET-CANARY';
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    final loader = _ControlledLibraryOverviewLoader();
    final container = ProviderContainer(
      overrides: [
        libraryOverviewLoaderProvider.overrideWithValue(loader),
        diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(libraryPageControllerProvider, (_, _) {}, fireImmediately: true);
    addTearDown(subscription.close);
    await _flush();
    loader.completeNext(_overview('durable'));
    await _flush();

    final operation = LibraryBookRemovalOperation(
      remover: _FailingBookRemover(StateError(secretCanary)),
      controller: container.read(libraryPageControllerProvider.notifier),
      diagnostics: diagnostics.manager,
    );
    await expectLater(operation.removeBook('book-durable'), throwsStateError);

    expect(container.read(libraryPageControllerProvider).overview!.items.single.title, 'durable');
    final error = diagnostics.sink.events.singleWhere((event) => event.eventName == 'library.operation.error');
    expect(error.outcome, DiagnosticOutcome.error);
    expect(jsonEncode(const DiagnosticEventCodec().encode(error)), isNot(contains(secretCanary)));
  });

  test('failed refresh records complete exception context for the developer console', () async {
    const failure = 'StateError: original refresh failure';
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    final operation = LibraryBookRefreshOperation(
      refresher: _FailingBookRefresher(StateError(failure)),
      diagnostics: diagnostics.manager,
    );

    await expectLater(operation.refresh('book-durable'), throwsStateError);

    final error = diagnostics.sink.events.singleWhere((event) => event.eventName == 'library.operation.error');
    expect(error.outcome, DiagnosticOutcome.error);
    expect((error.attributes.values['errorText'] as DiagnosticStringValue).value, contains(failure));
    expect((error.attributes.values['stackTrace'] as DiagnosticStringValue).value, isNotEmpty);
  });
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

LibraryOverview _overview(String title) {
  return LibraryOverview(
    items: <LibraryItemSummary>[LibraryItemSummary(id: 'book-$title', title: title)],
  );
}

final class _ControlledLibraryOverviewLoader implements LibraryOverviewLoader {
  final Queue<Completer<LibraryOverview>> _pending = Queue<Completer<LibraryOverview>>();

  int loadCount = 0;

  @override
  Future<LibraryOverview> load({Object? visibility}) {
    loadCount++;
    final Completer<LibraryOverview> completer = Completer<LibraryOverview>();
    _pending.add(completer);
    return completer.future;
  }

  void completeNext(LibraryOverview overview) {
    _pending.removeFirst().complete(overview);
  }

  void completeAt(int index, LibraryOverview overview) {
    _pending.elementAt(index).complete(overview);
  }

  void failNext(Object error) {
    _pending.removeFirst().completeError(error, StackTrace.current);
  }
}

final class _FailingBookRemover implements LibraryBookRemover {
  const _FailingBookRemover(this.error);

  final Object error;

  @override
  Future<void> removeBook(String bookId) => Future<void>.error(error);
}

final class _FailingBookRefresher implements LibraryBookRefresher {
  const _FailingBookRefresher(this.error);

  final Object error;

  @override
  Future<void> refresh(String bookId) => Future<void>.error(error);
}
