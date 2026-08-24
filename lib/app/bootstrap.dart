import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'package:mg_read/app/app.dart';
import 'package:mg_read/app/app_diagnostics_boundary.dart';
import 'package:mg_read/app/app_settings_lifecycle.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/persistence/persistence.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/application/library_book_remover.dart';
import 'package:mg_read/features/library/application/library_book_detail_launcher.dart';
import 'package:mg_read/features/library/data/content_library_book_remover.dart';
import 'package:mg_read/features/library/data/content_library_book_detail_launcher.dart';
import 'package:mg_read/features/library/data/content_library_overview_loader.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/discovery/application/discovery_bookshelf_saver.dart';
import 'package:mg_read/features/discovery/application/bookshelf_membership.dart';
import 'package:mg_read/features/discovery/application/content_library_source_prefetcher.dart';
import 'package:mg_read/features/discovery/application/source_cover_persistence.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/data/content_library_bookshelf_membership.dart';
import 'package:mg_read/features/discovery/data/content_library_source_cover_persistence.dart';
import 'package:mg_read/features/reader/application/library_reader_launcher.dart';
import 'package:mg_read/features/reader/data/content_library_source_text_reader.dart';
import 'package:mg_read/features/profile/application/profile_reading_stats_loader.dart';
import 'package:mg_read/features/profile/data/content_library_profile_reading_stats_loader.dart';

typedef SettingsDataRootResolver = Future<Directory> Function();
typedef MgReadAppRunner = void Function(Widget app);
typedef AppDiagnosticsServiceFactory =
    Future<AppDiagnosticsService> Function(Directory dataRoot);
typedef ContentLibraryFactory =
    Future<ContentLibrary> Function(
      Directory dataRoot,
      DiagnosticsManager diagnostics,
      AppPersistence? persistence,
    );
typedef AppPersistenceFactory =
    Future<AppPersistence> Function(
      Directory dataRoot,
      DiagnosticsManager diagnostics,
    );

/// Starts the Flutter host composition root.
///
/// This boundary owns framework initialization and the application ProviderScope.
/// Settings are opened on their background SQLite/JSON executors and fully
/// initialized before the explicitly overridden ProviderScope is mounted.
/// This boundary never starts the Node Runtime.
Future<void> bootstrapMgReadApp({
  AppSettingsManager? settingsManager,
  AppDiagnosticsService? diagnosticsService,
  DiagnosticsManager? diagnosticsManager,
  AppDiagnosticsServiceFactory? diagnosticsServiceFactory =
      _openDefaultDiagnostics,
  ContentLibrary? contentLibrary,
  ContentLibraryFactory? contentLibraryFactory = _openDefaultContentLibrary,
  AppPersistenceFactory? appPersistenceFactory = _openDefaultAppPersistence,
  SettingsDataRootResolver dataRootResolver = _defaultSettingsDataRoot,
  MgReadAppRunner appRunner = runApp,
  Widget child = const MgReadApp(),
}) async {
  if (diagnosticsService != null && diagnosticsManager != null) {
    throw ArgumentError(
      'Provide diagnosticsService or diagnosticsManager, not both.',
    );
  }
  WidgetsFlutterBinding.ensureInitialized();
  Directory? dataRoot;
  if ((contentLibrary == null && contentLibraryFactory != null) ||
      settingsManager == null ||
      (diagnosticsService == null &&
          diagnosticsManager == null &&
          diagnosticsServiceFactory != null)) {
    dataRoot = await dataRootResolver();
  }
  AppDiagnosticsService? persistentDiagnostics = diagnosticsService;
  if (persistentDiagnostics == null &&
      diagnosticsManager == null &&
      diagnosticsServiceFactory != null) {
    try {
      persistentDiagnostics = await diagnosticsServiceFactory(dataRoot!);
    } catch (_) {
      stderr.writeln(
        '[mg_read] diagnostics unavailable: diagnostics_open_failed',
      );
    }
  }
  final diagnostics =
      persistentDiagnostics?.manager ??
      diagnosticsManager ??
      DiagnosticsManager(
        sink: const NoopDiagnosticEventSink(),
        registry: AppDiagnosticEvents.registry,
        source: DiagnosticSource.app,
      );
  final errorBoundary = AppDiagnosticsErrorBoundary.install(diagnostics);
  ContentLibrary? persistentContentLibrary = contentLibrary;
  AppPersistence? sharedPersistence;
  AppSettingsManager? manager = settingsManager;
  final bootstrapStopwatch = Stopwatch()..start();
  final bootstrapSpan = diagnostics.startSpan(
    AppDiagnosticEvents.bootstrap,
    attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
      'stage': DiagnosticValue.string('composition'),
    }),
  );
  try {
    if (persistentContentLibrary == null && contentLibraryFactory != null) {
      if (appPersistenceFactory != null) {
        sharedPersistence = await appPersistenceFactory(dataRoot!, diagnostics);
      }
      persistentContentLibrary = await contentLibraryFactory(
        dataRoot!,
        diagnostics,
        sharedPersistence,
      );
    }
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
          dataRoot: dataRoot!,
          scope: const ScopeKey(kind: 'app', id: 'primary'),
          registry: AppSettingKeys.registry,
          diagnostics: diagnostics,
        );
      },
    );
    final resolvedManager = manager;
    await resolvedManager.initialize();
    appRunner(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(resolvedManager),
          diagnosticsManagerProvider.overrideWithValue(diagnostics),
          diagnosticsQueryProvider.overrideWithValue(persistentDiagnostics),
          diagnosticsCaptureProvider.overrideWithValue(persistentDiagnostics),
          diagnosticsMaintenanceProvider.overrideWithValue(
            persistentDiagnostics,
          ),
          if (persistentContentLibrary != null)
            libraryOverviewLoaderProvider.overrideWithValue(
              ContentLibraryOverviewLoader(persistentContentLibrary),
            ),
          if (persistentContentLibrary != null)
            libraryBookRemoverProvider.overrideWithValue(
              ContentLibraryBookRemover(persistentContentLibrary),
            ),
          if (persistentContentLibrary != null)
            libraryBookDetailLauncherProvider.overrideWithValue(
              ContentLibraryBookDetailLauncher(persistentContentLibrary),
            ),
          if (persistentContentLibrary != null)
            profileReadingStatsLoaderProvider.overrideWithValue(
              ContentLibraryProfileReadingStatsLoader(persistentContentLibrary),
            ),
          if (persistentContentLibrary != null)
            bookshelfMembershipLoaderProvider.overrideWithValue(
              ContentLibraryBookshelfMembershipLoader(persistentContentLibrary),
            ),
          if (persistentContentLibrary != null)
            discoveryBookshelfSaverProvider.overrideWith((ref) {
              final library = persistentContentLibrary!;
              final membership = ref.read(bookshelfMembershipProvider.notifier);
              return ContentLibraryDiscoveryBookshelfSaver(
                library,
                prefetcher: ContentLibrarySourcePrefetcher(
                  library,
                  ref.read(sourceContentGatewayProvider),
                  diagnostics: diagnostics,
                ),
                membership: membership,
                onMutationStarted: (mutation) {
                  ref
                      .read(libraryPageControllerProvider.notifier)
                      .beginAddition(
                        mutationId: mutation.id,
                        provisionalItem: _summaryFromShelfRequest(
                          mutation.id,
                          mutation.request,
                        ),
                      );
                },
                onMutationCommitted: (mutation, item) {
                  membership.markAdded(
                    pluginId: mutation.request.pluginId,
                    title: item.title,
                  );
                  ref
                      .read(libraryPageControllerProvider.notifier)
                      .commitAddition(
                        mutationId: mutation.id,
                        durableItem: _summaryFromLibraryItem(item),
                      );
                },
                onMutationFailed: (mutation) {
                  ref
                      .read(libraryPageControllerProvider.notifier)
                      .rollbackAddition(mutation.id);
                },
              );
            }),
          if (persistentContentLibrary != null)
            sourceCoverPersistenceProvider.overrideWithValue(
              ContentLibrarySourceCoverPersistence(persistentContentLibrary),
            ),
          if (persistentContentLibrary != null)
            libraryReaderLauncherProvider.overrideWith(
              (ref) => ContentLibrarySourceTextReader(
                persistentContentLibrary!,
                ref.read(sourceContentGatewayProvider),
              ),
            ),
        ],
        child: AppSettingsLifecycleHost(
          manager: resolvedManager,
          diagnostics: diagnostics,
          closeDiagnostics: persistentDiagnostics?.close ?? diagnostics.close,
          disposeDiagnosticsBoundary: errorBoundary.dispose,
          closeContentLibrary: persistentContentLibrary == null
              ? null
              : () => _closePersistenceResources(
                  persistentContentLibrary!,
                  sharedPersistence,
                ),
          child: child,
        ),
      ),
    );
    bootstrapSpan.complete(
      attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
        'stage': DiagnosticValue.string('mounted'),
      }),
    );
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
  } catch (error, stackTrace) {
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
    errorBoundary.dispose();
    await manager?.close();
    await persistentContentLibrary?.close();
    await sharedPersistence?.close();
    await (persistentDiagnostics?.close() ?? diagnostics.close());
    Error.throwWithStackTrace(error, stackTrace);
  }
}

Future<Directory> _defaultSettingsDataRoot() async {
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}${Platform.pathSeparator}persistence');
}

Future<AppDiagnosticsService> _openDefaultDiagnostics(Directory dataRoot) =>
    AppDiagnosticsService.open(
      dataRoot: dataRoot,
      configuration: PersistentDiagnosticsConfiguration(
        minimumSeverity: kReleaseMode
            ? DiagnosticSeverity.warn
            : DiagnosticSeverity.debug,
        eventMirror: kReleaseMode ? null : _DebugConsoleEventMirror().add,
      ),
      buildMode: kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug',
      platform: Platform.operatingSystem,
    );

/// Bounded, best-effort developer-console output outside the app log queue.
///
/// This keeps console backpressure, encoding, and I/O out of the user-action
/// path. On a VS Code desktop debug session [stderr] is the Debug Console;
/// Flutter's platform tooling owns the corresponding device stream on mobile.
final class _DebugConsoleEventMirror {
  static const int _maximumQueuedEvents = 256;
  static const int _maximumDrainBatch = 32;

  final DiagnosticConsoleFormatter _formatter =
      const DiagnosticConsoleFormatter();
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
    for (
      var index = 0;
      index < _maximumDrainBatch && _pending.isNotEmpty;
      index += 1
    ) {
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

Future<ContentLibrary> _openDefaultContentLibrary(
  Directory dataRoot,
  DiagnosticsManager diagnostics,
  AppPersistence? persistence,
) => persistence == null
    ? ContentLibrary.open(dataRoot: dataRoot, diagnostics: diagnostics)
    : Future<ContentLibrary>.value(
        ContentLibrary.fromPersistence(persistence, diagnostics: diagnostics),
      );

Future<AppPersistence> _openDefaultAppPersistence(
  Directory dataRoot,
  DiagnosticsManager diagnostics,
) => AppPersistence.open(
  dataRoot: dataRoot,
  registry: RecordDocumentRegistry(<RecordDocumentCodec>[
    ...contentLibraryRecordDocumentCodecs,
    ...settingsRecordDocumentCodecs(AppSettingKeys.registry, scopeKind: 'app'),
  ]),
  diagnostics: diagnostics,
);

Future<void> _closePersistenceResources(
  ContentLibrary contentLibrary,
  AppPersistence? sharedPersistence,
) async {
  await contentLibrary.close();
  await sharedPersistence?.close();
}

LibraryItemSummary _summaryFromShelfRequest(
  String mutationId,
  BookshelfAddRequest request,
) => LibraryItemSummary(
  id: 'pending-shelf:$mutationId',
  title: request.title,
  author: request.author,
  coverUrl: request.coverUrl,
  sourceName: request.sourceName,
);

LibraryItemSummary _summaryFromLibraryItem(LibraryItem item) =>
    LibraryItemSummary(
      id: item.id.value,
      title: item.title,
      author: item.author,
      coverUrl: item.coverUrl,
      sourceName: item.sourceName,
    );
