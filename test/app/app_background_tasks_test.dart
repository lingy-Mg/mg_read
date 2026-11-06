/// App-update launch, timer, idle and accepted-download progress regressions
/// without network or Runtime IO. Manifest streams yield on the event queue.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/app_background_tasks.dart';
import 'package:mg_read/app/app_navigation_activity.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/app_update/application/github_apk_update.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';
import 'package:mg_read/features/library/application/library_catalog_refresh_coordinator.dart';
import 'package:mg_read/features/media/application/source_audio_playback_service.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/application/source_collection_import.dart';
import 'package:mg_read/features/plugins/application/source_plugin_transfer_gateway.dart';
import 'package:mg_read/features/plugins/application/source_update_coordinator.dart';
import '../core/diagnostics/diagnostics_testkit.dart';
import '../core/settings/settings_testkit.dart';

void main() {
  testWidgets('source updates wait for ten idle seconds, download silently and leave active imports alone', (tester) async {
    final app = await _TestApp.create(tester);
    await app.settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, true);
    final gateway = _SilentSourceGateway();
    app.sourceUpdater = SourceUpdateCoordinator(
      settings: app.settings,
      catalog: _SourceCatalog(),
      gateway: gateway,
      installed: () async => const [
        PluginRuntimePlugin(
          activeVersion: '1.0.0',
          contentKinds: ['novel'],
          displayName: 'source',
          enabled: true,
          id: 'source',
          name: 'source',
          pendingVersion: null,
          status: 'active',
        ),
      ],
    );
    await app.start(tester);
    await app.elapse(tester, const Duration(seconds: 9));
    expect(gateway.stages, 0);
    app.router.go('/reader/book');
    await tester.pumpAndSettle();
    await app.elapse(tester, const Duration(minutes: 1));
    expect(gateway.stages, 0);
    app.router.go('/');
    await tester.pumpAndSettle();
    await app.elapse(tester, const Duration(seconds: 9));
    expect(gateway.stages, 0);
    await app.elapse(tester, const Duration(seconds: 1));
    expect(gateway.stages, 1);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('launch with a newer release shows the same update prompt without installing', (tester) async {
    final app = (await _TestApp.create(tester))..newRelease = true;
    await app.start(tester);
    expect(app.requests, 1);
    expect(app.installs, 0);
    expect(find.byKey(const Key('github-apk-update-prompt')), findsOneWidget);
    await tester.tap(find.byKey(const Key('github-apk-update-later')));
    await tester.pumpAndSettle();
    await app.elapse(tester, const Duration(minutes: 30));
    expect(app.requests, 2);
    expect(find.byKey(const Key('github-apk-update-prompt')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('accepting the launch update displays download progress until installation completes', (tester) async {
    final app = (await _TestApp.create(tester))..newRelease = true;
    final completeInstall = Completer<void>();
    app.install = (_, {onProgress}) async {
      app.installs++;
      onProgress!(const GitHubApkDownloadProgress(receivedBytes: 25, totalBytes: 100));
      await completeInstall.future;
    };
    await app.start(tester);
    await tester.tap(find.byKey(const Key('github-apk-update-install')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(app.installs, 1);
    expect(find.text('正在下载更新'), findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.25);
    completeInstall.complete();
    await tester.pumpAndSettle();
    expect(find.text('正在下载更新'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('local frame unlocks checks despite stalled Runtime and resumes honor failure backoff', (tester) async {
    final app = await _TestApp.create(tester);
    await tester.pumpWidget(app.widget);
    await tester.pump();
    expect(app.requests, 0);
    app.startup.signalLibraryTerminalFrame();
    await tester.pumpAndSettle();
    expect(app.requests, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    app.now = app.now.add(const Duration(minutes: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(app.requests, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(app.requests, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('each launch checks once even when a recent check would normally be skipped', (tester) async {
    final app = await _TestApp.create(tester);
    await app.updater.checkForUpdate(force: true);
    expect(app.requests, 1);
    expect((await app.updater.checkForUpdate()).status, UpdateCheckStatus.skipped);
    await app.start(tester);
    expect(app.requests, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app.widget);
    await tester.pumpAndSettle();
    expect(app.requests, 3);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('idle app checks every 30 minutes without navigation or lifecycle changes', (tester) async {
    final app = await _TestApp.create(tester);
    await app.start(tester);
    expect(app.requests, 1);
    await app.elapse(tester, const Duration(minutes: 29, seconds: 59));
    expect(app.requests, 1);
    await app.elapse(tester, const Duration(seconds: 1));
    expect(app.requests, 2);
    await app.elapse(tester, const Duration(minutes: 30));
    expect(app.requests, 3);
    await tester.pumpWidget(const SizedBox.shrink());
    await app.elapse(tester, const Duration(hours: 1));
    expect(app.requests, 3);
  });

  testWidgets('due checks wait for the reader route to return home', (tester) async {
    final app = await _TestApp.create(tester);
    await app.start(tester);
    app.router.go('/reader/book');
    await tester.pumpAndSettle();
    await app.elapse(tester, const Duration(minutes: 30));
    expect(app.requests, 1);
    app.router.go('/');
    await tester.pumpAndSettle();
    expect(app.requests, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('navigation before the due time does not postpone the timer', (tester) async {
    final app = await _TestApp.create(tester);
    await app.start(tester);
    await app.elapse(tester, const Duration(seconds: 30));
    app.router.go('/profile');
    await tester.pumpAndSettle();
    expect(app.requests, 1);
    await app.elapse(tester, const Duration(minutes: 29, seconds: 30));
    expect(app.requests, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('startup and timer checks run on settings pages even with a back stack', (tester) async {
    final app = await _TestApp.create(tester);
    await tester.pumpWidget(app.widget);
    app.router.go('/profile/settings');
    await tester.pumpAndSettle();
    expect(appRootNavigatorKey.currentState!.canPop(), isTrue);
    app.startup.signalLibraryTerminalFrame();
    await tester.pumpAndSettle();
    expect(app.requests, 1);
    await app.elapse(tester, const Duration(minutes: 30));
    expect(app.requests, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('startup and due checks wait for an imperative player or comic route to close', (tester) async {
    final app = await _TestApp.create(tester);
    await tester.pumpWidget(app.widget);
    await tester.pumpAndSettle();
    unawaited(appRootNavigatorKey.currentState!.push<void>(MaterialPageRoute(builder: (_) => const SizedBox.shrink())));
    await tester.pumpAndSettle();
    unawaited(
      appRootNavigatorKey.currentState!.push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: appContentSessionRouteName),
          builder: (_) => const SizedBox.shrink(),
        ),
      ),
    );
    app.startup.signalLibraryTerminalFrame();
    await tester.pumpAndSettle();
    expect(app.requests, 0);
    appRootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(app.requests, 1);
    expect(appRootNavigatorKey.currentState!.canPop(), isTrue);
    unawaited(
      appRootNavigatorKey.currentState!.push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: appContentSessionRouteName),
          builder: (_) => const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await app.elapse(tester, const Duration(minutes: 30));
    expect(app.requests, 1);
    appRootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(app.requests, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('minimized audio blocks checks and stopping it starts a fresh 30 minute cadence', (tester) async {
    final app = await _TestApp.create(tester);
    await app.start(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(AppBackgroundTasks)));
    final audio = container.read(_audioProvider.notifier);
    audio.setActive(true);
    await tester.pumpAndSettle();
    await app.elapse(tester, const Duration(minutes: 40));
    expect(app.requests, 1);
    audio.setActive(false);
    await tester.pumpAndSettle();
    expect(app.requests, 2);
    await app.elapse(tester, const Duration(minutes: 29, seconds: 59));
    expect(app.requests, 2);
    await app.elapse(tester, const Duration(seconds: 1));
    expect(app.requests, 3);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('background expiry is deferred until the app resumes', (tester) async {
    final app = await _TestApp.create(tester);
    await app.start(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await app.elapse(tester, const Duration(minutes: 30));
    expect(app.requests, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(app.requests, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('content activity follows push, pop, replacement and removal without marking ordinary routes', (tester) async {
    final navigation = AppNavigationActivity();
    final ordinary = MaterialPageRoute<void>(builder: (_) => const SizedBox.shrink());
    final content = MaterialPageRoute<void>(
      settings: const RouteSettings(name: appContentSessionRouteName),
      builder: (_) => const SizedBox.shrink(),
    );
    navigation.didPush(ordinary, null);
    expect(navigation.hasContentSession, isFalse);
    navigation.didPush(content, ordinary);
    expect(navigation.hasContentSession, isTrue);
    navigation.didReplace(oldRoute: content, newRoute: ordinary);
    expect(navigation.hasContentSession, isFalse);
    navigation.didReplace(oldRoute: ordinary, newRoute: content);
    expect(navigation.hasContentSession, isTrue);
    navigation.didRemove(content, ordinary);
    expect(navigation.hasContentSession, isFalse);
    navigation.didPush(content, ordinary);
    navigation.didPop(content, ordinary);
    expect(navigation.hasContentSession, isFalse);
    navigation.close();
    await tester.pump();
  });
}

final class _TestApp {
  _TestApp(this.startup, this.settings);
  final AppStartupController startup;
  final AppSettingsManager settings;
  SourceUpdateCoordinator? sourceUpdater;
  final navigation = AppNavigationActivity();
  final stalledRuntime = Completer<PluginRuntimeConnection>();
  var now = DateTime.utc(2026, 11, 1);
  var requests = 0;
  var newRelease = false;
  var installs = 0;
  Future<void> Function(GitHubApkRelease, {GitHubApkDownloadProgressCallback? onProgress}) install = (_, {onProgress}) async =>
      fail('checks must not install without consent');
  late final updater = GitHubApkUpdateCoordinator(
    currentVersion: () async => const AppVersionInfo(platform: AppUpdatePlatform.android, version: '1.0.0', buildNumber: 1),
    downloadAndInstall: (release, {onProgress}) => install(release, onProgress: onProgress),
    supportDirectory: () async => throw StateError('no disk in this test'),
    httpClientFactory: () => _Client(() => requests++, newRelease),
    clock: () => now,
    isAndroid: true,
  );
  late final router = GoRouter(
    navigatorKey: appRootNavigatorKey,
    observers: [navigation],
    routes: [
      for (final path in ['/', '/reader/:id']) GoRoute(path: path, builder: (_, _) => const SizedBox.shrink()),
      GoRoute(
        path: '/profile',
        builder: (_, _) => const SizedBox.shrink(),
        routes: [GoRoute(path: 'settings', builder: (_, _) => const SizedBox.shrink())],
      ),
    ],
  );

  static Future<_TestApp> create(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final diagnostics = DiagnosticsTestkit();
    final startup = AppStartupController(openResources: () async => const AppStartupResources(), diagnostics: diagnostics.manager);
    await startup.start();
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    await settings.initialize();
    await settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, false);
    await settings.flush();
    final app = _TestApp(startup, settings);
    addTearDown(() async {
      app.router.dispose();
      app.navigation.close();
      await startup.close();
      await settings.close();
      await diagnostics.dispose();
    });
    return app;
  }

  Widget get widget => ProviderScope(
    overrides: [
      appStartupControllerProvider.overrideWithValue(startup),
      appSettingsProvider.overrideWithValue(settings),
      appRouterProvider.overrideWithValue(router),
      appNavigationActivityProvider.overrideWithValue(navigation),
      githubApkUpdateCoordinatorProvider.overrideWithValue(updater),
      if (sourceUpdater != null) sourceUpdateCoordinatorProvider.overrideWithValue(sourceUpdater!),
      sourceAudioPlaybackServiceProvider.overrideWithBuild((ref, _) => ref.watch(_audioProvider)),
      libraryCatalogRefreshCoordinatorProvider.overrideWithValue(null),
      pluginRuntimeConnectionProvider.overrideWith((ref) => stalledRuntime.future),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      builder: (_, child) => Stack(children: [child!, const AppBackgroundTasks()]),
    ),
  );

  Future<void> start(WidgetTester tester) async {
    await tester.pumpWidget(widget);
    startup.signalLibraryTerminalFrame();
    await tester.pumpAndSettle();
    if (newRelease) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
    }
  }

  Future<void> elapse(WidgetTester tester, Duration duration) async {
    now = now.add(duration);
    await tester.pump(duration);
    await tester.pumpAndSettle();
    if (newRelease) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
    }
  }
}

final class _SourceCatalog implements OnlineSourceCatalogReader {
  @override
  Future<SourceCollection> loadCatalog() async => SourceCollection([
    SourceCollectionPlugin(
      id: 'source',
      name: 'source',
      version: '1.1.0',
      format: 'singleFile',
      byteLength: 1,
      checksum: '00000000',
      openBytes: () => Stream.value([1]),
    ),
  ]);
}

final class _SilentSourceGateway implements SourcePluginTransferGateway {
  int stages = 0;
  @override
  Future<List<PluginTransferPlanItem>> plan(List<PluginTransferArtifact> artifacts) async => [
    for (final artifact in artifacts)
      PluginTransferPlanItem(
        action: PluginTransferPlanAction.upgrade,
        pluginId: artifact.pluginId,
        receiverVersion: '1.0.0',
        version: artifact.version,
      ),
  ];
  @override
  Future<void> stageUpdates(List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})> artifacts) async {
    stages++;
    for (final input in artifacts) {
      await input.bytes.drain<void>();
    }
  }

  @override
  Future<List<PluginTransferImportResult>> importArtifacts(
    List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})> artifacts, {
    Set<String> forceUpgradePluginIds = const {},
  }) async => fail('Automatic downloads must not activate sources or prompt.');
}

final _audioProvider = NotifierProvider<_AudioState, SourceAudioPlaybackState>(_AudioState.new);

final class _AudioState extends Notifier<SourceAudioPlaybackState> {
  @override
  SourceAudioPlaybackState build() => const SourceAudioPlaybackState.inactive();

  void setActive(bool active) => state = active
      ? SourceAudioPlaybackState.active(
          sessionId: 1,
          request: _audioRequest(),
          presentation: SourceAudioPresentation.minimized,
          keepScreenOn: false,
        )
      : const SourceAudioPlaybackState.inactive();
}

SourceAudioPlaybackRequest _audioRequest() {
  final chapter = PluginChapterSummary(
    id: 'chapter',
    title: 'Chapter',
    order: 0,
    url: null,
    volumeTitle: null,
    wordCount: null,
    updatedAt: null,
    isLocked: false,
    attributes: const [],
  );
  final summary = PluginContentSummary(
    id: 'audio',
    title: 'Audio',
    contentKind: PluginContentKind.audio,
    author: null,
    url: null,
    coverUrl: null,
    description: null,
    language: null,
    status: PluginContentStatus.unknown,
    access: PluginAccessKind.unknown,
    wordCount: null,
    chapterCount: 1,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: const [],
    tags: const [],
    attributes: const [],
  );
  return SourceAudioPlaybackRequest(
    detail: PluginContentDetail(pluginId: 'source', sourceName: 'Source', summary: summary, aliases: const [], catalogUrl: null),
    firstCatalogPage: PluginChaptersResult(pluginId: 'source', sourceName: 'Source', items: [chapter]),
    chapter: chapter,
    libraryItemId: null,
  );
}

final class _Client implements HttpClient {
  _Client(this.onRequest, this.newRelease);
  final void Function() onRequest;
  final bool newRelease;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    onRequest();
    return _Request(newRelease);
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Request implements HttpClientRequest {
  _Request(this.newRelease);
  final bool newRelease;
  @override
  HttpHeaders get headers => _Headers();
  @override
  Future<HttpClientResponse> close() async => _Response(newRelease);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Headers implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.newRelease);
  final bool newRelease;
  @override
  int get statusCode => newRelease ? HttpStatus.ok : HttpStatus.serviceUnavailable;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(
    utf8.encode(
      jsonEncode({
        'schema': 'mgread.android-update.v1',
        'repository': 'lingy-Mg/mg_read',
        'version': '1.2.3',
        'buildNumber': 4,
        'tag': 'v1.2.3+4',
        'publishedAt': '2026-11-01T00:00:00Z',
        'releaseNotes': '修复更新提示',
        'apk': {'name': 'MgRead-1.2.3+4-android-arm64.apk', 'sha256': List.filled(64, 'a').join()},
      }),
    ),
  ).listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
