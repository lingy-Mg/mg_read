/// MgRead Flutter 启动组合根。
///
/// 职责：
/// - 在任何持久化或 Runtime IO 前挂载稳定的 ProviderScope 与真实应用壳。
/// - 在后台完成应用持久化、设置和诊断组合，并通过启动状态原地解锁。
///
/// 注意：
/// - Node Runtime 仍由根应用首帧后的独立预热流程启动。
/// - 启动期资源失败必须关闭已打开的资源，不能让启动界面持有业务状态。
///
/// TODO:
/// - 无。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'package:mg_read/app/app.dart';
import 'package:mg_read/app/app_diagnostics_boundary.dart';
import 'package:mg_read/app/app_fatal_error_reporter.dart';
import 'package:mg_read/app/app_settings_lifecycle.dart';
import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/persistence/persistence.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/application/library_book_remover.dart';
import 'package:mg_read/features/library/application/library_book_visibility_changer.dart';
import 'package:mg_read/features/library/application/library_book_detail_launcher.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/data/deferred_lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/data/mg_read_lan_sync_gateway.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/profile/application/profile_reading_stats_loader.dart';
import 'package:mg_read/features/discovery/application/bookshelf_membership.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';
import 'package:mg_read/features/reader/application/library_reader_launcher.dart';
import 'package:mg_read/features/reader/application/chapter_cache_task_controller.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/cache/application/cover_cache_manager.dart';
import 'package:mg_read/features/cache/application/database_cache_manager.dart';
import 'package:mg_read/features/cache/data/content_library_cover_cache_gateway.dart';
import 'package:mg_read/features/cache/data/content_library_database_cache_gateway.dart';
import 'package:mg_read/features/cache/data/content_library_manga_image_cache_gateway.dart';
import 'package:mg_read/features/discovery/application/discovery_bookshelf_saver.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';

typedef SettingsDataRootResolver = Future<Directory> Function();
typedef MgReadAppRunner = void Function(Widget app);
typedef AppDiagnosticsServiceFactory = Future<AppDiagnosticsService> Function(Directory dataRoot);
typedef ContentLibraryFactory =
    Future<ContentLibrary> Function(Directory dataRoot, DiagnosticsManager diagnostics, AppPersistence? persistence);
typedef AppPersistenceFactory = Future<AppPersistence> Function(Directory dataRoot, DiagnosticsManager diagnostics);

final class _UseDefaultDiagnosticsFactory {
  const _UseDefaultDiagnosticsFactory();
}

const _useDefaultDiagnosticsFactory = _UseDefaultDiagnosticsFactory();

/// Starts the Flutter host composition root.
///
/// This boundary owns framework initialization, the immediate startup surface,
/// and the application ProviderScope. The startup surface is mounted before
/// potentially slow first-run SQLite/JSON work so a desktop window always
/// exists while the explicitly overridden ProviderScope is composed. This
/// boundary never starts the Node Runtime.
Future<void> bootstrapMgReadApp({
  AppSettingsManager? settingsManager,
  AppDiagnosticsService? diagnosticsService,
  DiagnosticsManager? diagnosticsManager,
  Object? diagnosticsServiceFactory = _useDefaultDiagnosticsFactory,
  ContentLibrary? contentLibrary,
  ContentLibraryFactory? contentLibraryFactory = _openDefaultContentLibrary,
  AppPersistenceFactory? appPersistenceFactory = _openDefaultAppPersistence,
  SettingsDataRootResolver dataRootResolver = _defaultSettingsDataRoot,
  MgReadAppRunner appRunner = runApp,
  Widget child = const MgReadApp(),
}) async {
  if (diagnosticsService != null && diagnosticsManager != null) {
    throw ArgumentError('Provide diagnosticsService or diagnosticsManager, not both.');
  }
  WidgetsFlutterBinding.ensureInitialized();
  // The real ProviderScope and MgReadApp are mounted exactly once before any
  // application-support lookup or first-run database open.
  Future<Directory>? dataRootFuture;
  Future<Directory> resolveDataRoot() => dataRootFuture ??= dataRootResolver();
  final deferredDiagnostics = DeferredDiagnosticEventSink(
    minimumSeverity: kReleaseMode ? DiagnosticSeverity.warn : DiagnosticSeverity.debug,
  );
  final diagnostics =
      diagnosticsManager ??
      diagnosticsService?.manager ??
      DiagnosticsManager(
        sink: diagnosticsService == null ? deferredDiagnostics : const NoopDiagnosticEventSink(),
        registry: AppDiagnosticEvents.registry,
        source: DiagnosticSource.app,
      );
  final diagnosticsPorts = DeferredDiagnosticsPorts();
  if (diagnosticsService != null) diagnosticsPorts.attach(diagnosticsService);
  final fatalErrorReporter = AppFatalErrorReporter(diagnostics);
  final errorBoundary = AppDiagnosticsErrorBoundary.install(diagnostics, fatalReporter: fatalErrorReporter);
  AppPersistence? sharedPersistence;
  AppDiagnosticsService? persistentDiagnostics = diagnosticsService;
  AppSettingsManager? manager = settingsManager;
  manager ??= AppSettingsManager(
    registry: AppSettingKeys.registry,
    diagnostics: diagnostics,
    storeFactory: () async {
      final persistence = sharedPersistence;
      if (persistence != null) {
        return PersistentSettingsStore(
          records: persistence.metadataRecords,
          scope: const ScopeKey(kind: 'app', id: 'primary'),
          registry: AppSettingKeys.registry,
        );
      }
      return PersistentSettingsStore.open(
        dataRoot: await resolveDataRoot(),
        scope: const ScopeKey(kind: 'app', id: 'primary'),
        registry: AppSettingKeys.registry,
        diagnostics: diagnostics,
      );
    },
  );
  final resolvedManager = manager;
  late final AppStartupController startup;
  Future<AppDiagnosticsService?> openPersistentDiagnostics() async {
    final existing = persistentDiagnostics;
    if (existing != null) return existing;
    if (diagnosticsManager != null || diagnosticsServiceFactory == null) {
      return null;
    }
    try {
      final root = await resolveDataRoot();
      final usesDefaultFactory = identical(diagnosticsServiceFactory, _useDefaultDiagnosticsFactory);
      final service = usesDefaultFactory
          ? await _openDefaultDiagnostics(root, existingManager: diagnostics)
          : await (diagnosticsServiceFactory as AppDiagnosticsServiceFactory)(root);
      // The default service attaches the existing deferred manager while it
      // opens. Only an injected factory owns a separate manager that still
      // needs an explicit bridge here.
      if (!usesDefaultFactory) {
        await deferredDiagnostics.attach(service.manager.sink);
      }
      diagnosticsPorts.attach(service);
      persistentDiagnostics = service;
      startup.recordStage('diagnostics', resultState: 'ready');
      return service;
    } on Object {
      await deferredDiagnostics.disable();
      startup.recordStage('diagnostics', resultState: 'failure', errorCode: 'diagnostics_unavailable');
      return null;
    }
  }

  Future<AppStartupResources> openResources() async {
    AppPersistence? attemptPersistence;
    ContentLibrary? attemptLibrary = contentLibrary;
    try {
      if (attemptLibrary == null && contentLibraryFactory != null) {
        if (appPersistenceFactory != null) {
          attemptPersistence = await appPersistenceFactory(await resolveDataRoot(), diagnostics);
          sharedPersistence = attemptPersistence;
          startup.recordStage('persistence', resultState: 'ready');
        }
        attemptLibrary = await contentLibraryFactory(await resolveDataRoot(), diagnostics, attemptPersistence);
        startup.recordStage('library', resultState: 'ready');
      }
      if (startup.attemptNumber > 1 && resolvedManager.state == SettingsState.failed) {
        await resolvedManager.retryInitialization();
      } else {
        await resolvedManager.initialize();
      }
      if (resolvedManager.state != SettingsState.ready) {
        throw StateError('settings_not_ready');
      }
      startup.recordStage('settings', resultState: 'ready');
      return AppStartupResources(contentLibrary: attemptLibrary, persistence: attemptPersistence);
    } on Object {
      try {
        await attemptLibrary?.close();
      } catch (_) {}
      try {
        await attemptPersistence?.close();
      } catch (_) {}
      rethrow;
    }
  }

  startup = AppStartupController(
    openResources: openResources,
    diagnostics: diagnostics,
    diagnosticsServiceLoader: openPersistentDiagnostics,
    ownsLoadingAnimation: true,
  );
  Future<ContentLibrary> getLibrary() => startup.contentLibrary;
  startup.recordStage('composition', resultState: 'mounted');
  // Do this before any application-support lookup and first-run database open.
  appRunner(
    ProviderScope(
      overrides: [
        appStartupControllerProvider.overrideWithValue(startup),
        appSettingsProvider.overrideWithValue(resolvedManager),
        diagnosticsManagerProvider.overrideWithValue(diagnostics),
        fatalErrorReporterProvider.overrideWithValue(fatalErrorReporter),
        diagnosticsQueryProvider.overrideWithValue(diagnosticsService ?? diagnosticsPorts),
        diagnosticsCaptureProvider.overrideWithValue(diagnosticsService ?? diagnosticsPorts),
        diagnosticsMaintenanceProvider.overrideWithValue(diagnosticsService ?? diagnosticsPorts),
        if (contentLibrary != null || contentLibraryFactory != null)
          libraryOverviewLoaderProvider.overrideWithValue(DeferredLibraryOverviewLoader(startup)),
        if (contentLibrary != null || contentLibraryFactory != null)
          libraryBookRemoverProvider.overrideWithValue(DeferredLibraryBookRemover(getLibrary)),
        if (contentLibrary != null || contentLibraryFactory != null)
          libraryBookVisibilityChangerProvider.overrideWithValue(DeferredLibraryBookVisibilityChanger(getLibrary)),
        if (contentLibrary != null || contentLibraryFactory != null)
          libraryBookDetailLauncherProvider.overrideWithValue(DeferredLibraryBookDetailLauncher(getLibrary)),
        if (contentLibrary != null || contentLibraryFactory != null)
          profileReadingStatsLoaderProvider.overrideWithValue(DeferredProfileReadingStatsLoader(getLibrary)),
        if (contentLibrary != null || contentLibraryFactory != null)
          lanSyncGatewayProvider.overrideWith((ref) {
            final runtime = ref.watch(pluginRuntimeFacadeProvider);
            return DeferredLanSyncGateway(() async => MgReadLanSyncGateway(await getLibrary(), runtime));
          }),
        if (contentLibrary != null || contentLibraryFactory != null)
          bookshelfMembershipLoaderProvider.overrideWithValue(DeferredBookshelfMembershipLoader(getLibrary)),
        if (contentLibrary != null || contentLibraryFactory != null)
          discoveryBookshelfSaverProvider.overrideWith((ref) {
            final membership = ref.read(bookshelfMembershipProvider.notifier);
            return DeferredDiscoveryBookshelfSaver(
              getLibrary,
              ref.read(sourceContentGatewayProvider),
              diagnostics,
              membership,
              onMutationStarted: (mutation) => ref
                  .read(libraryPageControllerProvider.notifier)
                  .beginAddition(mutationId: mutation.id, provisionalItem: _summaryFromShelfRequest(mutation.id, mutation.request)),
              onMutationCommitted: (mutation, item) =>
                  ref.read(libraryPageControllerProvider.notifier).commitAddition(mutationId: mutation.id, durableItem: item),
              onMutationFailed: (mutation) => ref.read(libraryPageControllerProvider.notifier).rollbackAddition(mutation.id),
            );
          }),
        if (contentLibrary != null || contentLibraryFactory != null)
          bookCoverBytesLoaderProvider.overrideWithValue(DeferredBookCoverBytesLoader(getLibrary)),
        if (contentLibrary != null || contentLibraryFactory != null)
          coverCacheGatewayProvider.overrideWithValue(ContentLibraryCoverCacheGateway(getLibrary)),
        if (contentLibrary != null || contentLibraryFactory != null)
          databaseCacheGatewayProvider.overrideWithValue(ContentLibraryDatabaseCacheGateway(getLibrary)),
        if (contentLibrary != null || contentLibraryFactory != null)
          mangaImageCacheGatewayProvider.overrideWithValue(ContentLibraryMangaImageCacheGateway(getLibrary)),
        if (contentLibrary != null || contentLibraryFactory != null)
          libraryReaderLauncherProvider.overrideWith(
            (ref) => DeferredLibraryReaderLauncher(
              getLibrary,
              ref.read(sourceContentGatewayProvider),
              diagnostics,
              resolvedManager,
              ref.read(chapterCacheTaskControllerProvider.notifier),
            ),
          ),
      ],
      child: AppSettingsLifecycleHost(
        manager: resolvedManager,
        diagnostics: diagnostics,
        closeDiagnostics: null,
        disposeDiagnosticsBoundary: errorBoundary.dispose,
        disposeFatalErrorReporter: fatalErrorReporter.dispose,
        closeContentLibrary: startup.close,
        child: child,
      ),
    ),
  );
  final bootstrapStopwatch = Stopwatch()..start();
  final bootstrapSpan = diagnostics.startSpan(
    AppDiagnosticEvents.bootstrap,
    attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'stage': DiagnosticValue.string('composition')}),
  );
  await startup.start();
  if (startup.state.isReady) {
    bootstrapSpan.complete(attributes: DiagnosticObjectValue(<String, DiagnosticValue>{'stage': DiagnosticValue.string('mounted')}));
    bootstrapStopwatch.stop();
    reportSlowDiagnostic(
      diagnostics,
      subjectComponent: 'app.bootstrap',
      operation: 'composition',
      elapsed: bootstrapStopwatch.elapsed,
      threshold: AppDiagnosticThresholds.bootstrap,
      outcome: DiagnosticOutcome.success,
      traceContext: bootstrapSpan.traceContext,
    );
  } else {
    bootstrapSpan.fail(
      attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
        'stage': DiagnosticValue.string('failed'),
        'errorCode': DiagnosticValue.string('bootstrap_failed'),
      }),
    );
    bootstrapStopwatch.stop();
    reportSlowDiagnostic(
      diagnostics,
      subjectComponent: 'app.bootstrap',
      operation: 'composition',
      elapsed: bootstrapStopwatch.elapsed,
      threshold: AppDiagnosticThresholds.bootstrap,
      outcome: DiagnosticOutcome.error,
      traceContext: bootstrapSpan.traceContext,
    );
    // Startup failures are rendered in-place by the mounted gate. Keep the
    // process alive so the user can retry without replacing the container.
  }
}

Future<Directory> _defaultSettingsDataRoot() async {
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}${Platform.pathSeparator}persistence');
}

Future<AppDiagnosticsService> _openDefaultDiagnostics(Directory dataRoot, {DiagnosticsManager? existingManager}) =>
    AppDiagnosticsService.open(
      dataRoot: dataRoot,
      configuration: PersistentDiagnosticsConfiguration(
        minimumSeverity: kReleaseMode ? DiagnosticSeverity.warn : DiagnosticSeverity.debug,
        eventMirror: kReleaseMode ? null : _DebugConsoleEventMirror().add,
      ),
      buildMode: kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug',
      platform: Platform.operatingSystem,
      deferStartupMaintenance: true,
      existingManager: existingManager,
    );

/// Bounded, best-effort developer-console output outside the app log queue.
///
/// This keeps console backpressure, encoding, and I/O out of the user-action
/// path. On a VS Code desktop debug session [stderr] is the Debug Console;
/// Flutter's platform tooling owns the corresponding device stream on mobile.
final class _DebugConsoleEventMirror {
  static const int _maximumQueuedEvents = 256;
  static const int _maximumDrainBatch = 32;

  final DiagnosticConsoleFormatter _formatter = const DiagnosticConsoleFormatter();
  final ListQueue<String> _pending = ListQueue<String>();
  var _drainScheduled = false;

  void add(DiagnosticEvent event) {
    if (!_formatter.shouldMirror(event)) return;
    final String line;
    try {
      line = _formatter.format(event);
    } on Object {
      return;
    }
    if (_pending.length >= _maximumQueuedEvents) return;
    _pending.addLast(line);
    if (_drainScheduled) return;
    _drainScheduled = true;
    scheduleMicrotask(_drain);
  }

  void _drain() {
    _drainScheduled = false;
    for (var index = 0; index < _maximumDrainBatch && _pending.isNotEmpty; index += 1) {
      final line = _pending.removeFirst();
      try {
        stderr.writeln(line);
      } on Object {
        // Console output is strictly best-effort.
      }
    }
    if (_pending.isNotEmpty) {
      _drainScheduled = true;
      scheduleMicrotask(_drain);
    }
  }
}

Future<ContentLibrary> _openDefaultContentLibrary(Directory dataRoot, DiagnosticsManager diagnostics, AppPersistence? persistence) =>
    persistence == null
    ? ContentLibrary.open(dataRoot: dataRoot, diagnostics: diagnostics)
    : Future<ContentLibrary>.value(ContentLibrary.fromPersistence(persistence, diagnostics: diagnostics));

Future<AppPersistence> _openDefaultAppPersistence(Directory dataRoot, DiagnosticsManager diagnostics) => AppPersistence.open(
  dataRoot: dataRoot,
  registry: RecordDocumentRegistry(<RecordDocumentCodec>[
    ...contentLibraryRecordDocumentCodecs,
    ...settingsRecordDocumentCodecs(AppSettingKeys.registry, scopeKind: 'app'),
  ]),
  diagnostics: diagnostics,
);

LibraryItemSummary _summaryFromShelfRequest(String mutationId, BookshelfAddRequest request) => LibraryItemSummary(
  id: 'pending-shelf:$mutationId',
  title: request.title,
  author: request.author,
  coverUrl: request.coverUrl,
  coverPluginId: request.pluginId,
  coverPluginVersion: request.pluginVersion,
  coverRemoteContentId: request.remoteContentId,
  sourceName: request.sourceName,
  sourceUrl: request.sourceUrl,
  description: request.description,
  language: request.language,
  accessCode: request.accessCode,
  wordCount: request.wordCount,
  chapterCount: request.chapterCount,
  publishedAt: request.publishedAt,
  updatedAt: request.updatedAt,
  statusLabel: request.statusLabel,
  latestChapterId: request.latestChapterId,
  latestChapterTitle: request.latestChapterTitle,
  latestChapterUrl: request.latestChapterUrl,
  latestChapterUpdatedAt: request.latestChapterUpdatedAt,
  categories: request.categories,
  tags: request.tags,
  attributes: <LibraryItemSummaryAttribute>[
    for (final attribute in request.attributes)
      LibraryItemSummaryAttribute(key: attribute.key, label: attribute.label, value: attribute.value),
  ],
);
