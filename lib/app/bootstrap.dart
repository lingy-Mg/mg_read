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
import 'package:mg_read/features/library/data/content_library_overview_loader.dart';
import 'package:mg_read/features/discovery/application/discovery_bookshelf_saver.dart';

typedef SettingsDataRootResolver = Future<Directory> Function();
typedef MgReadAppRunner = void Function(Widget app);
typedef AppDiagnosticsServiceFactory =
    Future<AppDiagnosticsService> Function(Directory dataRoot);
typedef ContentLibraryFactory =
    Future<ContentLibrary> Function(
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
  final bootstrapStopwatch = Stopwatch()..start();
  final bootstrapSpan = diagnostics.startSpan(
    AppDiagnosticEvents.bootstrap,
    attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
      'stage': DiagnosticValue.string('composition'),
    }),
  );
  final manager =
      settingsManager ??
      AppSettingsManager(
        registry: AppSettingKeys.registry,
        diagnostics: diagnostics,
        storeFactory: () async => PersistentSettingsStore.open(
          dataRoot: dataRoot!,
          scope: const ScopeKey(kind: 'app', id: 'primary'),
          registry: AppSettingKeys.registry,
          diagnostics: diagnostics,
        ),
      );
  try {
    if (persistentContentLibrary == null && contentLibraryFactory != null) {
      persistentContentLibrary = await contentLibraryFactory(
        dataRoot!,
        diagnostics,
      );
    }
    await manager.initialize();
    appRunner(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(manager),
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
            discoveryBookshelfSaverProvider.overrideWithValue(
              ContentLibraryDiscoveryBookshelfSaver(persistentContentLibrary),
            ),
        ],
        child: AppSettingsLifecycleHost(
          manager: manager,
          diagnostics: diagnostics,
          closeDiagnostics: persistentDiagnostics?.close ?? diagnostics.close,
          disposeDiagnosticsBoundary: errorBoundary.dispose,
          closeContentLibrary: persistentContentLibrary?.close,
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
    await persistentContentLibrary?.close();
    await manager.close();
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
      ),
      buildMode: kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug',
      platform: Platform.operatingSystem,
    );

Future<ContentLibrary> _openDefaultContentLibrary(
  Directory dataRoot,
  DiagnosticsManager diagnostics,
) => ContentLibrary.open(dataRoot: dataRoot, diagnostics: diagnostics);
