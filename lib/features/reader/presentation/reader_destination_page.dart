import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/reader/application/library_reader_launcher.dart';
import 'package:mg_read/features/reader/application/reader_launch_failure.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'package:mg_read/features/reader/application/shelf_reader_launch_coordinator.dart';
import 'package:mg_read/features/reader/presentation/reader_host_page.dart';

DiagnosticObjectValue _stageAttributes(
  String stage,
  String resultState, {
  String? errorCode,
  Duration? duration,
}) => DiagnosticObjectValue(<String, DiagnosticValue>{
  'stage': DiagnosticValue.string(stage),
  'resultState': DiagnosticValue.string(resultState),
  if (duration != null)
    'durationMicros': DiagnosticValue.int64(duration.inMicroseconds),
  if (errorCode != null) 'errorCode': DiagnosticValue.string(errorCode),
});

/// Resolves a stable shelf ID into the reader's data source and state store.
class ReaderDestinationPage extends ConsumerStatefulWidget {
  const ReaderDestinationPage({required this.bookId, super.key});

  /// Stable, app-owned bookshelf identifier carried by the route.
  final String bookId;

  @override
  ConsumerState<ReaderDestinationPage> createState() =>
      _ReaderDestinationPageState();
}

class _ReaderDestinationPageState extends ConsumerState<ReaderDestinationPage> {
  late final DiagnosticsManager _diagnostics;
  late final LibraryReaderLauncher _launcher;
  late final LibraryPageController _libraryPageController;
  late final ShelfReaderLaunchCoordinator _shelfCoordinator;
  DiagnosticSpanHandle? _launchSpan;
  Stopwatch? _launchStopwatch;
  NavigatorState? _navigator;
  ReaderLaunchRequest? _request;
  DiagnosticSpanHandle? _readerMountStage;
  Object? _error;
  var _generation = 0;
  var _usesShelfCoordinator = false;

  @override
  void initState() {
    super.initState();
    _diagnostics = ref.read(diagnosticsManagerProvider);
    _launcher = ref.read(libraryReaderLauncherProvider);
    _libraryPageController = ref.read(libraryPageControllerProvider.notifier);
    _shelfCoordinator = ref.read(shelfReaderLaunchCoordinatorProvider.notifier);
    final prepared = _shelfCoordinator.takePrepared(widget.bookId);
    if (prepared != null) {
      _usesShelfCoordinator = true;
      _installRequest(prepared, _coordinatedStageReporter(_shelfCoordinator));
    } else {
      unawaited(_resolve());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
  }

  Future<void> _resolve() async {
    final generation = ++_generation;
    _startLaunchSpan();
    final stageReporter = _ReaderLaunchStageReporter(
      diagnostics: _diagnostics,
      parentTraceContext: _launchSpan?.traceContext,
    );
    setState(() {
      _request = null;
      _error = null;
    });
    try {
      final request = await stageReporter.measure(
        'mapping',
        () => _launcher.launch(widget.bookId),
      );
      if (!mounted || generation != _generation) return;
      _installRequest(request, stageReporter);
    } on Object catch (error) {
      _failLaunch(error);
      if (!mounted || generation != _generation) return;
      setState(() => _error = error);
    }
  }

  Future<void> _leaveReader(ReaderProgress? progress) {
    final NavigatorState? navigator = _navigator;
    if (navigator != null && navigator.mounted && navigator.canPop()) {
      navigator.pop();
    }
    // The shelf refresh is reconciliation work after navigation. It must not
    // hold the reader route open when persistence or another loader is slow.
    unawaited(_libraryPageController.refresh());
    return Future<void>.value();
  }

  _ReaderLaunchStageReporter _coordinatedStageReporter(
    ShelfReaderLaunchCoordinator coordinator,
  ) => _ReaderLaunchStageReporter(
    diagnostics: _diagnostics,
    parentTraceContext: null,
    startExternalStage: (String stage) =>
        coordinator.startStage(widget.bookId, stage),
  );

  void _installRequest(
    ReaderLaunchRequest request,
    _ReaderLaunchStageReporter stageReporter,
  ) {
    final coordinator = _shelfCoordinator;
    final mappingStage = _usesShelfCoordinator
        ? coordinator.startStage(widget.bookId, 'mapping')
        : null;
    final mountStage = _usesShelfCoordinator
        ? coordinator.startStage(widget.bookId, 'readerMount')
        : null;
    _readerMountStage = mountStage;
    _request = ReaderLaunchRequest(
      bookId: request.bookId,
      dataSource: _MeasuredTextReaderDataSource(
        request.dataSource,
        stageReporter,
      ),
      stateStore: _MeasuredTextReaderStateStore(
        request.stateStore,
        stageReporter,
      ),
      observer: _ReaderLaunchObserver(
        handleFirstContentPresented: _completeLaunch,
        handleFailure: _failLaunchFromReader,
        delegate: _ReaderObserverChain(<ReaderObserver>[
          ?request.observer,
          _ReaderExitObserver(_leaveReader),
        ]),
      ),
      controller: request.controller,
      extensions: request.extensions,
      estimatedWarmBytes: request.estimatedWarmBytes,
      preparationKind: request.preparationKind,
      networkPreparationElapsed: request.networkPreparationElapsed,
    );
    mappingStage?.complete(attributes: _stageAttributes('mapping', 'success'));
    if (mounted) setState(() {});
  }

  void _completeLaunch(ReaderFirstContentPresentation presentation) {
    final coordinator = _shelfCoordinator;
    if (_usesShelfCoordinator) {
      final layoutStage = coordinator.startStage(
        widget.bookId,
        'firstPageLayout',
      );
      layoutStage?.complete(
        attributes: _stageAttributes(
          'firstPageLayout',
          'success',
          duration: presentation.layoutDuration,
        ),
      );
      final frameStage = coordinator.startStage(
        widget.bookId,
        'firstContentFrame',
      );
      frameStage?.complete(
        attributes: _stageAttributes('firstContentFrame', 'success'),
      );
      coordinator.completeFirstContent(
        widget.bookId,
        preparationKind: presentation.paginationPreparation.name,
        firstPageLayout: presentation.layoutDuration,
        windowClass: _windowClass(),
      );
      return;
    }
    final span = _launchSpan;
    final stopwatch = _launchStopwatch;
    if (span == null || stopwatch == null || span.isEnded) return;
    stopwatch.stop();
    span.complete(
      attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
        'readerMode': DiagnosticValue.string('text'),
        'sourceKind': DiagnosticValue.string('shelf'),
        'resultState': DiagnosticValue.string('firstReadable'),
      }),
    );
    reportSlowDiagnostic(
      _diagnostics,
      subjectComponent: 'feature.reader',
      operation: 'firstReadable',
      elapsed: stopwatch.elapsed,
      threshold: AppDiagnosticThresholds.readerFirstFrame,
      outcome: DiagnosticOutcome.success,
      traceContext: span.traceContext,
    );
  }

  void _failLaunchFromReader(ReaderFailure failure) {
    if (_usesShelfCoordinator) {
      _shelfCoordinator.failFromReader(widget.bookId, 'reader_failure');
      return;
    }
    _finishLaunch(
      outcome: DiagnosticOutcome.error,
      resultState: 'failure',
      errorCode: 'reader_failure',
    );
  }

  void _failLaunch(Object error) {
    final failure = ReaderLaunchFailure.fromError(error);
    _finishLaunch(
      outcome: DiagnosticOutcome.error,
      resultState: 'failure',
      errorCode: failure.error.code.wireValue,
    );
  }

  void _finishLaunch({
    required DiagnosticOutcome outcome,
    required String resultState,
    String? errorCode,
  }) {
    final span = _launchSpan;
    final stopwatch = _launchStopwatch;
    if (span == null || stopwatch == null || span.isEnded) return;
    stopwatch.stop();
    final attributes = <String, DiagnosticValue>{
      'readerMode': DiagnosticValue.string('text'),
      'sourceKind': DiagnosticValue.string('shelf'),
      'resultState': DiagnosticValue.string(resultState),
    };
    if (errorCode != null) {
      attributes['errorCode'] = DiagnosticValue.string(errorCode);
    }
    span.end(outcome, attributes: DiagnosticObjectValue(attributes));
    reportSlowDiagnostic(
      _diagnostics,
      subjectComponent: 'feature.reader',
      operation: 'firstReadable',
      elapsed: stopwatch.elapsed,
      threshold: AppDiagnosticThresholds.readerFirstFrame,
      outcome: outcome,
      traceContext: span.traceContext,
    );
  }

  void _startLaunchSpan() {
    final previous = _launchSpan;
    if (previous != null && !previous.isEnded) {
      previous.cancel(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'readerMode': DiagnosticValue.string('text'),
          'sourceKind': DiagnosticValue.string('shelf'),
          'resultState': DiagnosticValue.string('superseded'),
        }),
      );
    }
    _launchStopwatch = Stopwatch()..start();
    _launchSpan = _diagnostics.startSpan(
      AppDiagnosticEvents.readerLaunch,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'readerMode': DiagnosticValue.string('text'),
        'sourceKind': DiagnosticValue.string('shelf'),
      }),
    );
  }

  @override
  void dispose() {
    if (_usesShelfCoordinator) {
      _shelfCoordinator.cancel(
        widget.bookId,
        resultState: 'disposedBeforeFirstContent',
      );
    } else {
      _finishLaunch(
        outcome: DiagnosticOutcome.cancelled,
        resultState: 'disposedBeforeFirstReadable',
      );
    }
    super.dispose();
  }

  String _windowClass() {
    final width = MediaQuery.sizeOf(context).width;
    if (width < 520) return 'compact';
    if (width < 720) return 'medium';
    return 'expanded';
  }

  @override
  Widget build(BuildContext context) {
    final request = _request;
    if (request != null) {
      final mountStage = _readerMountStage;
      if (mountStage != null && !mountStage.isEnded) {
        mountStage.complete(
          attributes: _stageAttributes('readerMount', 'success'),
        );
      }
      return ReaderHostPage(request: request);
    }
    final error = _error;
    if (error != null) {
      final failure = ReaderLaunchFailure.fromError(error);
      return Scaffold(
        appBar: AppBar(title: const Text('暂时无法开始阅读')),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(failure.reason.userMessage),
                  const SizedBox(height: 8),
                  Text('诊断代码：${failure.diagnosticCode}'),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => unawaited(_resolve()),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Scaffold(
      body: Center(
        child: Semantics(label: '正在准备阅读内容', child: CircularProgressIndicator()),
      ),
    );
  }
}

/// Emits bounded timing projections for the initial reader data path.
///
/// Stage names are fixed and intentionally carry no book, chapter, cache key,
/// title, author, URL, or content values. Their duration is recorded by the
/// diagnostics span itself.
final class _ReaderLaunchStageReporter {
  const _ReaderLaunchStageReporter({
    required this.diagnostics,
    required this.parentTraceContext,
    this.startExternalStage,
  });

  final DiagnosticsManager diagnostics;
  final DiagnosticTraceContext? parentTraceContext;
  final DiagnosticSpanHandle? Function(String stage)? startExternalStage;

  Future<T> measure<T>(String stage, Future<T> Function() action) async {
    if (diagnostics.isClosed) return action();
    DiagnosticSpanHandle? span = startExternalStage?.call(stage);
    try {
      span ??= diagnostics.startSpan(
        AppDiagnosticEvents.readerLaunchStage,
        parentContext: parentTraceContext,
        attributes: () => _stageAttributes(stage, 'started'),
      );
    } on Object {
      return action();
    }
    try {
      final result = await action();
      span.complete(attributes: _stageAttributes(stage, 'success'));
      return result;
    } on Object {
      span.fail(
        attributes: _stageAttributes(
          stage,
          'failure',
          errorCode: 'reader_stage_failed',
        ),
      );
      rethrow;
    }
  }
}

final class _MeasuredTextReaderDataSource implements TextReaderDataSource {
  const _MeasuredTextReaderDataSource(this._delegate, this._stages);

  final TextReaderDataSource _delegate;
  final _ReaderLaunchStageReporter _stages;

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) =>
      _stages.measure('metadata', () => _delegate.loadBookInfo(bookId));

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) => _stages.measure(
    'catalogTarget',
    () => _delegate.loadChapterCatalog(
      bookId,
      cursor: cursor,
      pageSize: pageSize,
    ),
  );

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) =>
      _stages.measure(
        'catalogTarget',
        () => _delegate.loadChapterAtIndex(bookId, index),
      );

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) => _stages.measure(
    'localContent',
    () => _delegate.loadChapterContent(bookId, chapterId),
  );
}

final class _MeasuredTextReaderStateStore implements TextReaderStateStore {
  const _MeasuredTextReaderStateStore(this._delegate, this._stages);

  final TextReaderStateStore _delegate;
  final _ReaderLaunchStageReporter _stages;

  @override
  Future<ReaderProgress?> loadProgress(String bookId) =>
      _stages.measure('progress', () => _delegate.loadProgress(bookId));

  @override
  Future<TextReaderPreferences?> loadPreferences() =>
      _stages.measure('preferencesLoad', _delegate.loadPreferences);

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) =>
      _stages.measure('bookmarksLoad', () => _delegate.loadBookmarks(bookId));

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) =>
      _delegate.saveProgress(bookId, progress);

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) =>
      _delegate.savePreferences(preferences);

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) =>
      _delegate.addBookmark(bookmark);

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) =>
      _delegate.removeBookmark(bookId, bookmarkId);
}

final class _ReaderExitObserver extends ReaderObserver {
  const _ReaderExitObserver(this._onExitRequested);

  final Future<void> Function(ReaderProgress? progress) _onExitRequested;

  @override
  Future<void> onExitRequested(ReaderProgress? progress) =>
      _onExitRequested(progress);
}

final class _ReaderObserverChain extends ReaderObserver {
  _ReaderObserverChain(Iterable<ReaderObserver> observers)
    : _observers = List<ReaderObserver>.unmodifiable(observers);

  final List<ReaderObserver> _observers;

  @override
  Future<void> onSessionStarted(String bookId) async {
    for (final observer in _observers) {
      await observer.onSessionStarted(bookId);
    }
  }

  @override
  Future<void> onFirstContentPresented(
    ReaderFirstContentPresentation presentation,
  ) async {
    for (final observer in _observers) {
      await observer.onFirstContentPresented(presentation);
    }
  }

  @override
  Future<void> onSessionEnded(String bookId, ReaderProgress? progress) async {
    for (final observer in _observers) {
      await observer.onSessionEnded(bookId, progress);
    }
  }

  @override
  Future<void> onLifecycleChanged(
    ReaderLifecycleState state,
    ReaderProgress? progress,
  ) async {
    for (final observer in _observers) {
      await observer.onLifecycleChanged(state, progress);
    }
  }

  @override
  Future<void> onChapterChanged(ReaderChapterInfo chapter) async {
    for (final observer in _observers) {
      await observer.onChapterChanged(chapter);
    }
  }

  @override
  Future<void> onFailure(ReaderFailure failure) async {
    for (final observer in _observers) {
      await observer.onFailure(failure);
    }
  }

  @override
  Future<void> onExitRequested(ReaderProgress? progress) async {
    for (final observer in _observers) {
      await observer.onExitRequested(progress);
    }
  }
}

final class _ReaderLaunchObserver extends ReaderObserver {
  const _ReaderLaunchObserver({
    required this.handleFirstContentPresented,
    required this.handleFailure,
    required this.delegate,
  });

  final void Function(ReaderFirstContentPresentation presentation)
  handleFirstContentPresented;
  final void Function(ReaderFailure failure) handleFailure;
  final ReaderObserver delegate;

  @override
  Future<void> onSessionStarted(String bookId) async {
    await delegate.onSessionStarted(bookId);
  }

  @override
  Future<void> onFirstContentPresented(
    ReaderFirstContentPresentation presentation,
  ) async {
    handleFirstContentPresented(presentation);
    await delegate.onFirstContentPresented(presentation);
  }

  @override
  Future<void> onFailure(ReaderFailure failure) async {
    handleFailure(failure);
    await delegate.onFailure(failure);
  }

  @override
  Future<void> onSessionEnded(String bookId, ReaderProgress? progress) async {
    await delegate.onSessionEnded(bookId, progress);
  }

  @override
  Future<void> onLifecycleChanged(
    ReaderLifecycleState state,
    ReaderProgress? progress,
  ) async {
    await delegate.onLifecycleChanged(state, progress);
  }

  @override
  Future<void> onChapterChanged(ReaderChapterInfo chapter) async {
    await delegate.onChapterChanged(chapter);
  }

  @override
  Future<void> onExitRequested(ReaderProgress? progress) async {
    await delegate.onExitRequested(progress);
  }
}
