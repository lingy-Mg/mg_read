/// Stable application startup state and deferred composition adapters.
///
/// The startup controller is deliberately independent from routing. It owns
/// one resource attempt, exposes safe retry, and keeps the Riverpod container
/// stable while persistence and the local Content Library open asynchronously.
/// Source-backed shelf saves and reader launches receive one lifecycle-scoped
/// prefetch coordinator from bootstrap so their per-book work stays single-flight.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_content_library_source_prefetcher_coordinator.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/core/persistence/persistence.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/library/application/library_overview_loader.dart';
import 'package:mg_read/features/library/application/library_book_remover.dart';
import 'package:mg_read/features/library/application/library_book_visibility_changer.dart';
import 'package:mg_read/features/library/application/library_book_detail_launcher.dart';
import 'package:mg_read/features/library/application/library_book_refresher.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/data/content_library_overview_loader.dart';
import 'package:mg_read/features/library/data/content_library_book_remover.dart';
import 'package:mg_read/features/library/data/content_library_book_visibility_changer.dart';
import 'package:mg_read/features/library/data/content_library_book_detail_launcher.dart';
import 'package:mg_read/features/library/data/content_library_book_refresher.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';
import 'package:mg_read/features/profile/application/profile_reading_stats_loader.dart';
import 'package:mg_read/features/profile/data/content_library_profile_reading_stats_loader.dart';
import 'package:mg_read/features/profile/domain/profile_reading_stats.dart';
import 'package:mg_read/features/discovery/application/bookshelf_membership.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/application/discovery_bookshelf_saver.dart';
import 'package:mg_read/features/discovery/data/content_library_bookshelf_membership.dart';
import 'package:mg_read/features/discovery/data/content_library_source_cover_persistence.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/notifications/application/notification_center.dart';
import 'package:mg_read/features/notifications/data/content_library_notification_center.dart';
import 'package:mg_read/features/reader/application/library_reader_launcher.dart';
import 'package:mg_read/features/reader/application/chapter_cache_task_controller.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'package:mg_read/features/reader/application/shelf_reader_launch_coordinator.dart';
import 'package:mg_read/features/reader/data/content_library_source_comic_reader.dart';
import 'package:mg_read/features/reader/data/content_library_source_text_reader.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

enum AppStartupStatus { booting, ready, retryableFailure }

@immutable
final class AppStartupState {
  const AppStartupState._(this.status, {this.errorCode});

  const AppStartupState.booting() : this._(AppStartupStatus.booting);
  const AppStartupState.ready() : this._(AppStartupStatus.ready);
  const AppStartupState.retryableFailure(String code) : this._(AppStartupStatus.retryableFailure, errorCode: code);

  final AppStartupStatus status;
  final String? errorCode;

  bool get isBooting => status == AppStartupStatus.booting;
  bool get isReady => status == AppStartupStatus.ready;
}

final appStartupControllerProvider = Provider<AppStartupController>((ref) {
  // Isolated feature/widget tests intentionally compose MgReadApp without
  // the desktop bootstrap. Keep that contract usable while production
  // bootstrap always overrides this provider with the real controller.
  final diagnostics = DiagnosticsManager(
    sink: const NoopDiagnosticEventSink(),
    registry: AppDiagnosticEvents.registry,
    source: DiagnosticSource.app,
  );
  final controller = AppStartupController(openResources: () async => const AppStartupResources(), diagnostics: diagnostics)
    ..state = const AppStartupState.ready();
  ref.onDispose(() {
    unawaited(controller.close());
  });
  return controller;
});

typedef AppStartupResourcesFactory = Future<AppStartupResources> Function();
typedef ContentLibraryGetter = Future<ContentLibrary> Function();
typedef AppDiagnosticsServiceLoader = Future<AppDiagnosticsService?> Function();

/// Resources that remain owned by the application lifecycle host.
final class AppStartupResources {
  const AppStartupResources({this.contentLibrary, this.persistence, this.diagnosticsService});

  final ContentLibrary? contentLibrary;
  final AppPersistence? persistence;
  final AppDiagnosticsService? diagnosticsService;
}

/// Owns one startup attempt at a time. A retry while booting returns the same
/// future, preventing duplicate opens and duplicate Runtime-adjacent work.
final class AppStartupController extends ValueNotifier<AppStartupState> {
  AppStartupController({
    required this.openResources,
    required this.diagnostics,
    this.diagnosticsServiceLoader,
    this.ownsLoadingAnimation = false,
  }) : super(const AppStartupState.booting());

  final AppStartupResourcesFactory openResources;
  final DiagnosticsManager diagnostics;
  final AppDiagnosticsServiceLoader? diagnosticsServiceLoader;
  final bool ownsLoadingAnimation;

  AppStartupState get state => value;
  set state(AppStartupState next) => value = next;
  int get attemptNumber => _attemptNumber;
  bool get requiresLibraryFrame => _resources?.contentLibrary != null;
  bool get hasLibraryTerminalFrame => _libraryFrameRecorded;
  bool get isInteractive => state.isReady && (!requiresLibraryFrame || hasLibraryTerminalFrame);
  bool get isClosed => _disposed;

  Future<void>? _attempt;
  Future<ContentLibrary>? _libraryFuture;
  Future<void>? _libraryTerminalFrame;
  Completer<void>? _libraryTerminalCompleter;
  AppStartupResources? _resources;
  Future<AppDiagnosticsService?>? _diagnosticsServiceFuture;
  bool _disposed = false;
  bool _shellFrameRecorded = false;
  bool _libraryFrameRecorded = false;
  int _attemptNumber = 0;
  final Stopwatch _elapsed = Stopwatch()..start();

  Future<void> start() => _runIfNeeded();

  Future<void> retry() {
    final inFlight = _attempt;
    if (inFlight != null) return inFlight;
    final previousFrame = _libraryTerminalCompleter;
    if (previousFrame != null && !previousFrame.isCompleted) {
      previousFrame.complete();
    }
    state = const AppStartupState.booting();
    _libraryTerminalCompleter = Completer<void>();
    _libraryTerminalFrame = _libraryTerminalCompleter!.future;
    return _runIfNeeded(force: true);
  }

  Future<ContentLibrary> get contentLibrary => _libraryFuture ??= _openLibraryFuture();

  Future<void> waitForLibraryTerminalFrame() => _libraryTerminalFrame ??= (() {
    _libraryTerminalCompleter ??= Completer<void>();
    return _libraryTerminalCompleter!.future;
  })();

  /// Completes only when the successfully opened application has rendered its
  /// terminal library frame. Failed attempts remain parked until retry.
  Future<void> waitForSuccessfulLibraryTerminalFrame() {
    bool isSuccessfulTerminalFrame() => state.isReady && hasLibraryTerminalFrame;
    if (isSuccessfulTerminalFrame() || _disposed) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    late VoidCallback listener;
    listener = () {
      if (!isSuccessfulTerminalFrame() && !_disposed) return;
      removeListener(listener);
      if (!completer.isCompleted) completer.complete();
    };
    addListener(listener);
    listener();
    return completer.future;
  }

  void signalLibraryTerminalFrame({String resultState = 'ready'}) {
    if (!_libraryFrameRecorded) {
      _libraryFrameRecorded = true;
      recordStage('libraryFirstUsableFrame', resultState: resultState);
      // The gate listens to this notification while startup.status remains
      // ready. This unlocks the real route without replacing its container.
      notifyListeners();
    }
    final completer = _libraryTerminalCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void recordShellFirstFrame({String resultState = 'booting'}) {
    if (_shellFrameRecorded) return;
    _shellFrameRecorded = true;
    recordStage('shellFirstFrame', resultState: resultState);
  }

  void recordStage(String stage, {required String resultState, String? errorCode, int? attempt, int? durationMicros}) {
    try {
      diagnostics.emit(
        AppDiagnosticEvents.startupStage,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'stage': DiagnosticValue.string(stage),
          'durationMicros': DiagnosticValue.int64(durationMicros ?? _elapsed.elapsedMicroseconds),
          'resultState': DiagnosticValue.string(resultState),
          if (errorCode != null) 'errorCode': DiagnosticValue.string(errorCode),
          'attempt': DiagnosticValue.int64(attempt ?? _attemptNumber),
        }),
      );
    } catch (_) {}
  }

  /// Runs optional diagnostics retention only after Runtime warmup has
  /// finished. Diagnostics maintenance is intentionally fail-open.
  Future<String> runDeferredDiagnosticsMaintenance() async {
    final resourceService = _resources?.diagnosticsService;
    final pendingService = _diagnosticsServiceFuture;
    final service = resourceService ?? (pendingService == null ? null : await pendingService.catchError((_) => null));
    if (service == null) return 'skipped';
    try {
      await service.enforceRetention(service.configuration.retentionPolicy).timeout(const Duration(seconds: 5));
      return 'complete';
    } on TimeoutException {
      return 'timeout';
    } catch (_) {
      return 'failure';
    }
  }

  /// Opens persistent diagnostics on demand. Normal startup calls this only
  /// after the first usable library frame and Runtime warmup; a startup failure
  /// may call it earlier to make the safe diagnostics route available.
  Future<AppDiagnosticsService?> ensureDiagnosticsReady() {
    final resourceService = _resources?.diagnosticsService;
    if (resourceService != null) {
      return Future<AppDiagnosticsService?>.value(resourceService);
    }
    final loader = diagnosticsServiceLoader;
    if (loader == null) return Future<AppDiagnosticsService?>.value();
    return _diagnosticsServiceFuture ??= _loadDiagnosticsFailOpen(loader);
  }

  Future<AppDiagnosticsService?> _loadDiagnosticsFailOpen(AppDiagnosticsServiceLoader loader) async {
    try {
      return await loader();
    } catch (_) {
      return null;
    }
  }

  Future<void> _runIfNeeded({bool force = false}) {
    final inFlight = _attempt;
    if (inFlight != null) return inFlight;
    if (!force && state.isReady) return Future<void>.value();
    final attemptNumber = ++_attemptNumber;
    _shellFrameRecorded = false;
    _libraryFrameRecorded = false;
    _resources = null;
    final future = _openAttempt(attemptNumber);
    _attempt = future;
    future.whenComplete(() {
      if (identical(_attempt, future)) _attempt = null;
    });
    return future;
  }

  Future<void> _openAttempt(int attemptNumber) async {
    _libraryFuture = null;
    _libraryTerminalCompleter ??= Completer<void>();
    _libraryTerminalFrame ??= _libraryTerminalCompleter!.future;
    try {
      final resources = await openResources();
      if (_disposed) {
        await _closeResources(resources);
        return;
      }
      _resources = resources;
      state = const AppStartupState.ready();
      recordStage('resourcesReady', resultState: 'ready', attempt: attemptNumber);
    } on Object catch (error) {
      final resources = _resources;
      if (resources != null) await _closeResources(resources);
      _resources = null;
      if (!_disposed) {
        final normalized = AppError.fromUnknown(error);
        state = AppStartupState.retryableFailure(normalized.code.wireValue);
        recordStage('resourcesReady', resultState: 'retryableFailure', errorCode: normalized.code.wireValue, attempt: attemptNumber);
      }
    }
  }

  Future<ContentLibrary> _openLibraryFuture() async {
    await _runIfNeeded();
    final resources = _resources;
    final library = resources?.contentLibrary;
    if (library != null) return library;
    try {
      // This future is intentionally allowed to complete with the same safe
      // startup failure that the gate displays; it can never yield a false
      // empty overview.
      final attempt = _attempt;
      if (attempt != null) await attempt;
      final current = _resources;
      if (current == null) throw StateError('startup_failed');
      final currentLibrary = current.contentLibrary;
      if (currentLibrary == null) throw StateError('startup_failed');
      return currentLibrary;
    } finally {
      // A retry receives a fresh future; the old failed loader is discarded by
      // the library controller when the gate invalidates it.
    }
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    notifyListeners();
    final terminalFrame = _libraryTerminalCompleter;
    if (terminalFrame != null && !terminalFrame.isCompleted) {
      terminalFrame.complete();
    }
    final attempt = _attempt;
    if (attempt != null) await attempt.catchError((_) {});
    final resources = _resources;
    _resources = null;
    if (resources != null) await _closeResources(resources);
    final diagnosticsFuture = _diagnosticsServiceFuture;
    final service = diagnosticsFuture == null ? null : await diagnosticsFuture.catchError((_) => null);
    if (service != null && !identical(service, resources?.diagnosticsService)) {
      try {
        await service.close();
      } catch (_) {}
    }
    if (service == null || !identical(service.manager, diagnostics)) {
      try {
        await diagnostics.close();
      } catch (_) {}
    }
    dispose();
  }

  Future<void> _closeResources(AppStartupResources resources) async {
    try {
      await resources.contentLibrary?.close();
    } catch (_) {}
    try {
      await resources.persistence?.close();
    } catch (_) {}
    try {
      await resources.diagnosticsService?.close();
    } catch (_) {}
  }
}

/// Stable diagnostics capability ports. They are attached once persistent
/// diagnostics opens, so routes do not need a ProviderScope replacement.
final class DeferredDiagnosticsPorts implements DiagnosticsQuery, DiagnosticsCapture, DiagnosticsMaintenance, DiagnosticsLogArchive {
  DeferredDiagnosticsPorts({DiagnosticsLogArchive? coldArchive}) : _archive = coldArchive;

  DiagnosticsQuery? _query;
  DiagnosticsCapture? _capture;
  DiagnosticsMaintenance? _maintenance;
  DiagnosticsLogArchive? _archive;

  void attach(AppDiagnosticsService service) {
    _query = service;
    _capture = service;
    _maintenance = service;
    _archive = service;
  }

  Future<T> _unavailable<T>() => Future<T>.error(StateError('diagnostics_unavailable'));

  @override
  Future<DiagnosticPage<DiagnosticSession>> listSessions({
    DiagnosticSessionFilter filter = const DiagnosticSessionFilter(),
    DiagnosticCursor? cursor,
    int limit = 100,
  }) => _query?.listSessions(filter: filter, cursor: cursor, limit: limit) ?? _unavailable();
  @override
  Future<DiagnosticPage<DiagnosticEvent>> listEvents({required DiagnosticEventFilter filter, DiagnosticCursor? cursor, int limit = 100}) =>
      _query?.listEvents(filter: filter, cursor: cursor, limit: limit) ?? _unavailable();
  @override
  Future<DiagnosticEvent?> getEvent(String eventId) => _query?.getEvent(eventId) ?? _unavailable();
  @override
  Future<List<DiagnosticAttachmentDescriptor>> listAttachments(String eventId) => _query?.listAttachments(eventId) ?? _unavailable();
  @override
  Stream<List<int>> openAttachment(String attachmentId, {DiagnosticByteRange? range}) =>
      _query?.openAttachment(attachmentId, range: range) ?? const Stream<List<int>>.empty();
  @override
  Future<DiagnosticPage<DiagnosticStructuredNode>> listStructuredNodes(
    String attachmentId, {
    required String path,
    DiagnosticCursor? cursor,
    int limit = 100,
  }) => _query?.listStructuredNodes(attachmentId, path: path, cursor: cursor, limit: limit) ?? _unavailable();
  @override
  Future<DiagnosticSession> startCapture(DiagnosticCapturePolicy policy) => _capture?.startCapture(policy) ?? _unavailable();
  @override
  Future<void> stopCapture(String sessionId) => _capture?.stopCapture(sessionId) ?? _unavailable();
  @override
  Future<DiagnosticAttachmentDescriptor> captureAttachment({
    required String eventId,
    required String kind,
    required String mediaType,
    required String formatId,
    required int formatVersion,
    required Stream<List<int>> bytes,
    String? charset,
    String? schemaId,
    int? schemaVersion,
  }) =>
      _capture?.captureAttachment(
        eventId: eventId,
        kind: kind,
        mediaType: mediaType,
        formatId: formatId,
        formatVersion: formatVersion,
        bytes: bytes,
        charset: charset,
        schemaId: schemaId,
        schemaVersion: schemaVersion,
      ) ??
      _unavailable();
  @override
  Future<DiagnosticMaintenanceResult> enforceRetention(DiagnosticRetentionPolicy policy) =>
      _maintenance?.enforceRetention(policy) ?? _unavailable();
  @override
  Future<void> deleteSession(String sessionId) => _maintenance?.deleteSession(sessionId) ?? _unavailable();
  @override
  Future<DiagnosticExportResult> exportBundle({required DiagnosticExportSelection selection, required DiagnosticExportPolicy policy}) =>
      _maintenance?.exportBundle(selection: selection, policy: policy) ?? _unavailable();
  @override
  Future<List<DiagnosticLogFile>> listLogFiles() => _archive?.listLogFiles() ?? _unavailable();
  @override
  Future<DiagnosticPage<DiagnosticEvent>> listLogEvents(String fileId, {DiagnosticCursor? cursor, int limit = 100}) =>
      _archive?.listLogEvents(fileId, cursor: cursor, limit: limit) ?? _unavailable();
  @override
  Future<DiagnosticEvent?> getLogEvent(String fileId, String eventId) => _archive?.getLogEvent(fileId, eventId) ?? _unavailable();
  @override
  Future<List<DiagnosticAttachmentDescriptor>> listLogAttachments(String fileId, String eventId) =>
      _archive?.listLogAttachments(fileId, eventId) ?? _unavailable();
  @override
  Stream<List<int>> openLogAttachment(String fileId, String attachmentId, {DiagnosticByteRange? range}) =>
      _archive?.openLogAttachment(fileId, attachmentId, range: range) ?? const Stream<List<int>>.empty();
  @override
  Future<void> deleteLogFile(String fileId) => _archive?.deleteLogFile(fileId) ?? _unavailable();
  @override
  Future<DiagnosticExportResult> exportLogFile(String fileId) => _archive?.exportLogFile(fileId) ?? _unavailable();
}

/// Content-library adapter that waits for startup resources instead of
/// returning an empty overview while the real library is still opening.
final class DeferredLibraryOverviewLoader implements LibraryOverviewLoader {
  const DeferredLibraryOverviewLoader(this.controller);
  final AppStartupController controller;

  @override
  Future<LibraryOverview> load({LibraryVisibility visibility = LibraryVisibility.normal}) async {
    final library = await controller.contentLibrary;
    return ContentLibraryOverviewLoader(library).load(visibility: visibility);
  }
}

final class DeferredLibraryBookRemover implements LibraryBookRemover {
  const DeferredLibraryBookRemover(this._get);
  final ContentLibraryGetter _get;
  @override
  Future<void> removeBook(String bookId) async => ContentLibraryBookRemover(await _get()).removeBook(bookId);
}

final class DeferredLibraryBookVisibilityChanger implements LibraryBookVisibilityChanger {
  const DeferredLibraryBookVisibilityChanger(this._get);
  final ContentLibraryGetter _get;
  @override
  Future<void> setBookVisibility(String bookId, LibraryVisibility visibility) async =>
      ContentLibraryBookVisibilityChanger(await _get()).setBookVisibility(bookId, visibility);
}

final class DeferredLibraryBookDetailLauncher implements LibraryBookDetailLauncher {
  const DeferredLibraryBookDetailLauncher(this._get);
  final ContentLibraryGetter _get;
  @override
  Future<LibraryBookDetailLaunchData> load(String bookId) async => ContentLibraryBookDetailLauncher(await _get()).load(bookId);
}

final class DeferredLibraryBookRefresher implements LibraryBookRefresher {
  const DeferredLibraryBookRefresher(this._get, this._gateway);
  final ContentLibraryGetter _get;
  final SourceContentGateway _gateway;

  @override
  Future<void> refresh(String bookId) async => ContentLibraryBookRefresher(await _get(), _gateway).refresh(bookId);
}

final class DeferredProfileReadingStatsLoader implements ProfileReadingStatsLoader {
  const DeferredProfileReadingStatsLoader(this._get);
  final ContentLibraryGetter _get;
  @override
  Future<ProfileReadingStats> load() async => ContentLibraryProfileReadingStatsLoader(await _get()).load();
}

/// Defers the first notification query until the notification page opens.
final class DeferredNotificationCenter implements NotificationCenter {
  const DeferredNotificationCenter(this._get);

  final ContentLibraryGetter _get;

  @override
  Future<List<LibraryNotification>> load() async => ContentLibraryNotificationCenter(await _get()).load();

  @override
  Future<void> clear() async => ContentLibraryNotificationCenter(await _get()).clear();
}

final class DeferredBookshelfMembershipLoader implements BookshelfMembershipLoader {
  const DeferredBookshelfMembershipLoader(this._get);
  final ContentLibraryGetter _get;
  @override
  Future<Iterable<BookshelfMembershipEntry>> load() async => ContentLibraryBookshelfMembershipLoader(await _get()).load();
}

final class DeferredBookCoverBytesLoader implements BookCoverBytesLoader {
  const DeferredBookCoverBytesLoader(this._get);
  final ContentLibraryGetter _get;
  @override
  Future<List<int>?> resolve(BookCoverRequest request) async => ContentLibrarySourceCoverPersistence(await _get()).resolve(request);
}

final class DeferredDiscoveryBookshelfSaver implements DiscoveryBookshelfSaver {
  const DeferredDiscoveryBookshelfSaver(
    this._get,
    this._gateway,
    this._membership, {
    required this.prefetchers,
    this.onMutationStarted,
    this.onMutationCommitted,
    this.onMutationFailed,
  });
  final ContentLibraryGetter _get;
  final SourceContentGateway _gateway;
  final BookshelfMembershipController _membership;
  final AppContentLibrarySourcePrefetcherCoordinator prefetchers;
  final void Function(DiscoveryBookshelfMutation mutation)? onMutationStarted;
  final void Function(DiscoveryBookshelfMutation mutation, LibraryItemSummary item)? onMutationCommitted;
  final void Function(DiscoveryBookshelfMutation mutation)? onMutationFailed;

  @override
  Future<void> save({required PluginSourceDescriptor source, PluginContentSummary? content, PluginContentDetail? detail}) async {
    final library = await _get();
    await ContentLibraryDiscoveryBookshelfSaver(
      library,
      prefetcher: prefetchers.resolve(library, _gateway),
      membership: _membership,
      onMutationStarted: onMutationStarted,
      onMutationCommitted: (mutation, item) {
        _membership.markAdded(itemId: item.id.value, pluginId: mutation.request.pluginId, title: item.title);
        onMutationCommitted?.call(
          mutation,
          LibraryItemSummary(
            id: item.id.value,
            title: item.title,
            contentKind: item.kind,
            author: item.author,
            coverUrl: item.coverUrl,
            coverPluginId: item.source?.pluginId,
            coverPluginVersion: item.source?.pluginVersion,
            coverRemoteContentId: item.source?.remoteContentId,
            sourceName: item.sourceName,
            sourceUrl: item.sourceUrl,
            description: item.description,
            language: item.language,
            accessCode: item.accessCode,
            wordCount: item.wordCount,
            chapterCount: item.chapterCount,
            publishedAt: item.publishedAt,
            updatedAt: item.updatedAt,
            statusLabel: item.statusLabel,
            latestChapterId: item.latestChapterId,
            latestChapterTitle: item.latestChapterTitle,
            latestChapterUrl: item.latestChapterUrl,
            latestChapterUpdatedAt: item.latestChapterUpdatedAt,
            categories: item.categories,
            tags: item.tags,
            attributes: <LibraryItemSummaryAttribute>[
              for (final attribute in item.attributes)
                LibraryItemSummaryAttribute(key: attribute.key, label: attribute.label, value: attribute.value),
            ],
          ),
        );
      },
      onMutationFailed: onMutationFailed,
    ).save(source: source, content: content, detail: detail);
  }
}

final class DeferredLibraryReaderLauncher implements LibraryReaderLauncher, LocalShelfReaderPrewarmer {
  const DeferredLibraryReaderLauncher(
    this._get,
    this._gateway,
    this._prefetchers, [
    this._settings,
    this._chapterCacheTasks,
    this._proxyManager,
  ]);
  final ContentLibraryGetter _get;
  final SourceContentGateway _gateway;
  final AppContentLibrarySourcePrefetcherCoordinator _prefetchers;
  final AppSettingsManager? _settings;
  final ChapterCacheTaskController? _chapterCacheTasks;
  final FlutterNetworkProxyManager? _proxyManager;
  @override
  Future<ReaderLaunchRequest> launch(String libraryItemId) async {
    final library = await _get();
    final item = await library.getLibraryItem(LibraryItemId(libraryItemId));
    if (item == null) {
      return _textReader(library).launch(libraryItemId);
    }
    return switch (item.kind) {
      ContentKind.novel => _textReader(library).launch(libraryItemId),
      ContentKind.manga => ComicReaderLaunchRequest(
        bookId: item.id.value,
        entryCoverBytes: await _readCachedCover(library, item),
        dataSource: ContentLibraryComicReaderDataSource(
          library: library,
          gateway: _gateway,
          item: item,
          httpClientFactory: _proxyManager == null ? null : createProxyAwareComicHttpClientFactory(_proxyManager),
        ),
        stateStore: ContentLibraryComicReaderStateStore(library, itemId: item.id, settings: _settings),
      ),
      ContentKind.audio || ContentKind.video => throw StateError('Media shelf items must be opened through their player host.'),
    };
  }

  @override
  Future<ReaderLaunchRequest?> warmLocal(String libraryItemId) async {
    final library = await _get();
    final item = await library.getLibraryItem(LibraryItemId(libraryItemId));
    if (item == null || item.kind != ContentKind.novel) return null;
    return _textReader(library).warmLocal(libraryItemId);
  }

  ContentLibrarySourceTextReader _textReader(ContentLibrary library) =>
      ContentLibrarySourceTextReader(library, _gateway, _prefetchers.resolve(library, _gateway), _settings, _chapterCacheTasks);

  Future<List<int>?> _readCachedCover(ContentLibrary library, LibraryItem item) async {
    try {
      final source = item.source;
      final url = item.coverUrl;
      if (source != null && url != null) {
        final cached = await library.covers.read(
          CoverKey(pluginId: source.pluginId, pluginVersion: source.pluginVersion, remoteContentId: source.remoteContentId, coverUrl: url),
        );
        if (cached != null && cached.isNotEmpty) return cached;
      }
      final legacy = await library.bookshelf.readCover(item.id);
      return legacy == null || legacy.isEmpty ? null : legacy;
    } on Object {
      // A cover-cache failure must not prevent the comic reader from opening.
      return null;
    }
  }
}
