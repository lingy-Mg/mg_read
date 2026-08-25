import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/reader/application/library_reader_launcher.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'package:mg_read/features/reader/application/shelf_reader_launch_coordinator.dart';

import '../../../core/diagnostics/diagnostics_testkit.dart';

void main() {
  test('deduplicates repeated taps and permits one navigation', () async {
    final launcher = _ControlledLauncher();
    final container = ProviderContainer(
      overrides: [libraryReaderLauncherProvider.overrideWithValue(launcher)],
    );
    addTearDown(container.dispose);
    final coordinator = container.read(
      shelfReaderLaunchCoordinatorProvider.notifier,
    );

    final first = coordinator.prepare('book-1');
    final second = coordinator.prepare('book-1');
    expect(launcher.launchCount, 1);
    expect(
      container
          .read(shelfReaderLaunchCoordinatorProvider)
          .isPreparing('book-1'),
      isTrue,
    );

    launcher.complete(_request('book-1'));
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(coordinator.claimNavigation('book-1'), isTrue);
    expect(coordinator.claimNavigation('book-1'), isFalse);
    expect(coordinator.takePrepared('book-1'), isNotNull);
    expect(coordinator.takePrepared('book-1'), isNull);
  });

  test('a failed preparation remains retryable', () async {
    final launcher = _ControlledLauncher();
    final container = ProviderContainer(
      overrides: [libraryReaderLauncherProvider.overrideWithValue(launcher)],
    );
    addTearDown(container.dispose);
    final coordinator = container.read(
      shelfReaderLaunchCoordinatorProvider.notifier,
    );

    final first = coordinator.prepare('book-2');
    launcher.fail(StateError('content unavailable'));
    expect(await first, isFalse);
    expect(
      container.read(shelfReaderLaunchCoordinatorProvider).status,
      ShelfReaderPreparationStatus.failed,
    );

    launcher.reset();
    final retry = coordinator.prepare('book-2');
    launcher.complete(_request('book-2'));
    expect(await retry, isTrue);
    expect(launcher.launchCount, 2);
  });

  test('disposing the shelf prevents later navigation readiness', () async {
    final launcher = _ControlledLauncher();
    final container = ProviderContainer(
      overrides: [libraryReaderLauncherProvider.overrideWithValue(launcher)],
    );
    final coordinator = container.read(
      shelfReaderLaunchCoordinatorProvider.notifier,
    );
    final pending = coordinator.prepare('book-3');

    container.dispose();
    launcher.complete(_request('book-3'));

    expect(await pending, isFalse);
  });

  test('closed diagnostics never prevents a valid reader launch', () async {
    final diagnostics = DiagnosticsManager(
      sink: const NoopDiagnosticEventSink(),
      registry: AppDiagnosticEvents.registry,
      source: DiagnosticSource.app,
    );
    await diagnostics.close();
    final launcher = _ControlledLauncher();
    final container = ProviderContainer(
      overrides: [
        libraryReaderLauncherProvider.overrideWithValue(launcher),
        diagnosticsManagerProvider.overrideWithValue(diagnostics),
      ],
    );
    addTearDown(container.dispose);
    final coordinator = container.read(
      shelfReaderLaunchCoordinatorProvider.notifier,
    );

    final pending = coordinator.prepare('book-4');
    launcher.complete(_request('book-4'));

    expect(await pending, isTrue);
    expect(coordinator.claimNavigation('book-4'), isTrue);
    expect(coordinator.takePrepared('book-4'), isNotNull);
  });

  test(
    'launch diagnostics have one terminal and omit content canaries',
    () async {
      const sensitiveBookId = 'BOOK_SECRET_CANARY_正文不得记录';
      final kit = DiagnosticsTestkit();
      final launcher = _ControlledLauncher();
      final container = ProviderContainer(
        overrides: [
          libraryReaderLauncherProvider.overrideWithValue(launcher),
          diagnosticsManagerProvider.overrideWithValue(kit.manager),
        ],
      );
      addTearDown(kit.dispose);
      addTearDown(container.dispose);
      expect(container.read(diagnosticsManagerProvider), same(kit.manager));
      expect(kit.manager.isEnabled(AppDiagnosticEvents.readerLaunch), isTrue);
      final coordinator = container.read(
        shelfReaderLaunchCoordinatorProvider.notifier,
      );

      final pending = coordinator.prepare(sensitiveBookId);
      launcher.complete(_request(sensitiveBookId));
      expect(await pending, isTrue);
      expect(coordinator.claimNavigation(sensitiveBookId), isTrue);
      expect(coordinator.takePrepared(sensitiveBookId), isNotNull);
      coordinator.completeFirstContent(
        sensitiveBookId,
        preparationKind: ReaderPaginationPreparation.firstPage.name,
        firstPageLayout: const Duration(milliseconds: 2),
        windowClass: 'compact',
      );

      final launchEvents = kit.sink.events
          .where(
            (event) =>
                event.eventName.startsWith(
                  '${AppDiagnosticEvents.readerLaunch.name}.',
                ) &&
                event.parentSpanId == null,
          )
          .toList();
      expect(
        launchEvents.where((event) => event.phase == DiagnosticPhase.start),
        hasLength(1),
      );
      expect(
        launchEvents.where((event) => event.phase == DiagnosticPhase.terminal),
        hasLength(1),
      );
      final encoded = jsonEncode(
        kit.sink.events.map(const DiagnosticEventCodec().encode).toList(),
      );
      expect(encoded, isNot(contains(sensitiveBookId)));
      expect(encoded, isNot(contains('正文不得记录')));
    },
  );
}

ReaderLaunchRequest _request(String bookId) => ReaderLaunchRequest(
  bookId: bookId,
  dataSource: _UnusedDataSource(),
  stateStore: _UnusedStateStore(),
);

final class _ControlledLauncher implements LibraryReaderLauncher {
  Completer<ReaderLaunchRequest> _completer = Completer<ReaderLaunchRequest>();
  int launchCount = 0;

  @override
  Future<ReaderLaunchRequest> launch(
    String libraryItemId, {
    ReaderObserver? observer,
  }) {
    launchCount += 1;
    return _completer.future;
  }

  void complete(ReaderLaunchRequest request) => _completer.complete(request);

  void fail(Object error) => _completer.completeError(error);

  void reset() {
    _completer = Completer<ReaderLaunchRequest>();
  }
}

final class _UnusedDataSource implements TextReaderDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _UnusedStateStore implements TextReaderStateStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
