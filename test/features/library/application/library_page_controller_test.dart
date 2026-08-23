import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/library/application/library_overview_loader.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/application/library_page_state.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';

import '../../../core/diagnostics/diagnostics_testkit.dart';

void main() {
  test(
    'keeps the successful overview when the page listener is replaced',
    () async {
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

      final firstSubscription = container.listen(
        libraryPageControllerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      await _flush();
      expect(loader.loadCount, 1);
      loader.completeNext(_overview('cached'));
      await _flush();
      firstSubscription.close();

      final secondSubscription = container.listen(
        libraryPageControllerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(secondSubscription.close);
      await _flush();

      expect(loader.loadCount, 1);
      expect(
        container
            .read(libraryPageControllerProvider)
            .overview!
            .items
            .single
            .title,
        'cached',
      );
    },
  );

  test('latest request generation wins when refreshes overlap', () async {
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    final _ControlledLibraryOverviewLoader loader =
        _ControlledLibraryOverviewLoader();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        libraryOverviewLoaderProvider.overrideWithValue(loader),
        diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
      ],
    );
    addTearDown(container.dispose);
    final ProviderSubscription<LibraryPageState> subscription = container
        .listen(
          libraryPageControllerProvider,
          (_, _) {},
          fireImmediately: true,
        );
    addTearDown(subscription.close);

    await _flush();
    loader.completeNext(_overview('initial'));
    await _flush();

    final LibraryPageController controller = container.read(
      libraryPageControllerProvider.notifier,
    );
    final Future<void> olderRefresh = controller.refresh();
    final Future<void> newerRefresh = controller.refresh();

    loader.completeAt(1, _overview('newer'));
    await _flush();
    loader.completeAt(0, _overview('older'));
    await Future.wait(<Future<void>>[olderRefresh, newerRefresh]);
    await _flush();

    final LibraryPageState state = container.read(
      libraryPageControllerProvider,
    );
    expect(state.status, LibraryPageStatus.content);
    expect(state.overview!.items.single.title, 'newer');

    final libraryEvents = diagnostics.sink.events
        .where((event) => event.eventName.startsWith('library.load.'))
        .toList(growable: false);
    final terminalEvents = libraryEvents
        .where((event) => event.phase == DiagnosticPhase.terminal)
        .toList(growable: false);
    expect(
      terminalEvents.map((event) => event.outcome),
      containsAll(<DiagnosticOutcome>[
        DiagnosticOutcome.success,
        DiagnosticOutcome.cancelled,
      ]),
    );
    for (final start in libraryEvents.where(
      (event) => event.phase == DiagnosticPhase.start,
    )) {
      expect(
        terminalEvents.where((event) => event.spanId == start.spanId),
        hasLength(1),
      );
    }
  });

  test(
    'retains old data while refreshing and replaces it after completion',
    () async {
      final diagnostics = DiagnosticsTestkit();
      addTearDown(diagnostics.dispose);
      final _ControlledLibraryOverviewLoader loader =
          _ControlledLibraryOverviewLoader();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          libraryOverviewLoaderProvider.overrideWithValue(loader),
          diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
        ],
      );
      addTearDown(container.dispose);
      final ProviderSubscription<LibraryPageState> subscription = container
          .listen(
            libraryPageControllerProvider,
            (_, _) {},
            fireImmediately: true,
          );
      addTearDown(subscription.close);

      await _flush();
      loader.completeNext(_overview('old data'));
      await _flush();

      final Future<void> refresh = container
          .read(libraryPageControllerProvider.notifier)
          .refresh();
      await _flush();
      final LibraryPageState refreshing = container.read(
        libraryPageControllerProvider,
      );
      expect(refreshing.status, LibraryPageStatus.refreshing);
      expect(refreshing.overview!.items.single.title, 'old data');

      loader.completeNext(_overview('complete data'));
      await refresh;
      expect(
        container
            .read(libraryPageControllerProvider)
            .overview!
            .items
            .single
            .title,
        'complete data',
      );
      expect(
        container.read(libraryPageControllerProvider).status,
        LibraryPageStatus.content,
      );
    },
  );

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
    final subscription = container.listen(
      libraryPageControllerProvider,
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    await _flush();
    loader.completeNext(_overview('durable'));
    await _flush();
    final controller = container.read(libraryPageControllerProvider.notifier);

    controller.beginAddition(
      mutationId: 'source:pending',
      provisionalItem: const LibraryItemSummary(
        id: 'pending-shelf:source:pending',
        title: '立即出现',
      ),
    );
    expect(
      container.read(libraryPageControllerProvider).overview!.items
          .map((item) => item.title),
      contains('立即出现'),
    );

    controller.commitAddition(
      mutationId: 'source:pending',
      durableItem: const LibraryItemSummary(id: 'book-committed', title: '立即出现'),
    );
    await _flush();
    loader.failNext(StateError('refresh unavailable'));
    await _flush();
    expect(
      container.read(libraryPageControllerProvider).overview!.items
          .map((item) => item.title),
      contains('立即出现'),
    );
    expect(container.read(libraryPageControllerProvider).hasFailure, isFalse);

    controller.beginRemoval('book-durable');
    expect(
      container.read(libraryPageControllerProvider).overview!.items
          .map((item) => item.title),
      isNot(contains('durable')),
    );
    controller.rollbackRemoval('book-durable');
    expect(
      container.read(libraryPageControllerProvider).overview!.items
          .map((item) => item.title),
      contains('durable'),
    );
  });

  test(
    'load failure records a stable code without exception content',
    () async {
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
      final subscription = container.listen(
        libraryPageControllerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await _flush();
      loader.failNext(StateError(secretCanary));
      await _flush();

      expect(container.read(libraryPageControllerProvider).hasFailure, isTrue);
      final terminal = diagnostics.sink.events.singleWhere(
        (event) => event.eventName == 'library.load.error',
      );
      expect(terminal.outcome, DiagnosticOutcome.error);
      expect(
        jsonEncode(const DiagnosticEventCodec().encode(terminal)),
        isNot(contains(secretCanary)),
      );
    },
  );
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

LibraryOverview _overview(String title) {
  return LibraryOverview(
    items: <LibraryItemSummary>[
      LibraryItemSummary(id: 'book-$title', title: title),
    ],
  );
}

final class _ControlledLibraryOverviewLoader implements LibraryOverviewLoader {
  final Queue<Completer<LibraryOverview>> _pending =
      Queue<Completer<LibraryOverview>>();

  int loadCount = 0;

  @override
  Future<LibraryOverview> load() {
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
