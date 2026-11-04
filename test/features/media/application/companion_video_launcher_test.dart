import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/app/app_tv_companion_video.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';
import 'package:mg_read/features/tv_companion/application/companion_command_engine.dart';
import 'package:mg_read/features/tv_companion/domain/companion_command.dart';
import 'package:mg_read/features/tv_companion/domain/companion_models.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';

import '../../../support/tv_media_test_fixture.dart';
import '../../../core/settings/settings_testkit.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (_) async => const StandardMessageCodec().encodeMessage([null]),
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      null,
    );
  });
  testWidgets('unavailable source fails before replacing the current route', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sourceContentGatewayProvider.overrideWithValue(_Gateway())],
        child: MaterialApp(
          navigatorKey: appRootNavigatorKey,
          home: const Scaffold(body: Text('Current route')),
        ),
      ),
    );
    final context = tester.element(find.text('Current route'));
    final container = ProviderScope.containerOf(context, listen: false);
    final engine = container.read(_handoffEngineProvider);
    engine.grantControl('phone-a');

    final receipt = await engine.execute(
      'phone-a',
      CompanionCommand(
        id: 'handoff-1',
        hostEpoch: 'test-epoch',
        clientSeq: 1,
        controlGeneration: engine.controlGeneration,
        playbackGeneration: engine.playbackGeneration,
        deadlineMs: 5000,
        type: CompanionCommandType.handoff,
        arguments: const CompanionContentRef(
          pluginId: 'removed-source',
          contentId: 'video-1',
          title: 'Video',
          groupId: 'line-1',
          episodeId: 'ep-1',
        ).toJson(),
      ),
    );

    expect(receipt.phase, CompanionCommandPhase.failed);
    expect(receipt.code, 'video_source_unavailable');
    expect(find.text('Current route'), findsOneWidget);
    expect(appRootNavigatorKey.currentState?.canPop(), isFalse);
    await engine.close();
  });

  testWidgets('known phone plugin version mismatch is a stable preflight failure', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourceContentGatewayProvider.overrideWithValue(
            _Gateway(
              sources: <PluginSourceDescriptor>[
                PluginSourceDescriptor(
                  id: 'source',
                  displayName: 'Source',
                  contentKinds: const [PluginContentKind.video],
                  pluginVersion: '2.0',
                ),
              ],
            ),
          ),
        ],
        child: MaterialApp(
          navigatorKey: appRootNavigatorKey,
          home: const Scaffold(body: Text('Current route')),
        ),
      ),
    );
    final context = tester.element(find.text('Current route'));
    final engine = ProviderScope.containerOf(context, listen: false).read(_handoffEngineProvider);
    engine.grantControl('phone-a');
    final receipt = await engine.execute(
      'phone-a',
      CompanionCommand(
        id: 'version-mismatch',
        hostEpoch: 'test-epoch',
        clientSeq: 1,
        controlGeneration: engine.controlGeneration,
        playbackGeneration: engine.playbackGeneration,
        deadlineMs: 5000,
        type: CompanionCommandType.handoff,
        arguments: const CompanionContentRef(
          pluginId: 'source',
          pluginVersion: '1.0',
          contentId: 'video-1',
          title: 'Video',
          groupId: 'line-1',
          episodeId: 'ep-1',
        ).toJson(),
      ),
    );
    expect(receipt.code, 'source_version_mismatch');
    expect(find.text('Current route'), findsOneWidget);
    expect(appRootNavigatorKey.currentState?.canPop(), isFalse);
    await engine.close();
  });

  testWidgets('prepared handoff adopts one first-frame backend into the active route', (tester) async {
    final root = (await tester.runAsync(() => Directory.systemTemp.createTemp('mg-read-companion-handoff-')))!;
    final library = (await tester.runAsync(() => ContentLibrary.open(dataRoot: root)))!;
    final diagnostics = DiagnosticsManager(
      sink: const NoopDiagnosticEventSink(),
      registry: AppDiagnosticEvents.registry,
      source: DiagnosticSource.app,
    );
    final startup = AppStartupController(
      openResources: () async => AppStartupResources(contentLibrary: library),
      diagnostics: diagnostics,
    );
    await tester.runAsync(startup.start);
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    var backendCreations = 0;
    final gateway = _Gateway(
      sources: <PluginSourceDescriptor>[
        PluginSourceDescriptor(
          id: 'tv-fixture',
          displayName: 'Fixture',
          contentKinds: const [PluginContentKind.video],
          pluginVersion: '1.0',
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourceContentGatewayProvider.overrideWithValue(gateway),
          appStartupControllerProvider.overrideWithValue(startup),
          appSettingsProvider.overrideWithValue(settings),
          diagnosticsManagerProvider.overrideWithValue(diagnostics),
          deviceIdentityStoreProvider.overrideWithValue(const _IdentityStore()),
          _testBackendFactoryProvider.overrideWithValue(() {
            backendCreations++;
            return _Backend();
          }),
        ],
        child: MaterialApp(
          navigatorKey: appRootNavigatorKey,
          theme: AppTheme.light(),
          home: const Scaffold(body: Text('Old route')),
        ),
      ),
    );
    final context = tester.element(find.text('Old route'));
    final container = ProviderScope.containerOf(context, listen: false);
    final engine = container.read(_handoffEngineProvider);
    engine.grantControl('phone-a');
    final result = Completer<CompanionReceipt>();
    await tester.runAsync(() async {
      engine
          .execute(
            'phone-a',
            CompanionCommand(
              id: 'positive-handoff',
              hostEpoch: 'test-epoch',
              clientSeq: 1,
              controlGeneration: engine.controlGeneration,
              playbackGeneration: engine.playbackGeneration,
              deadlineMs: 5000,
              type: CompanionCommandType.handoff,
              arguments: const CompanionContentRef(
                pluginId: 'tv-fixture',
                pluginVersion: '1.0',
                contentId: 'show',
                title: 'Show',
                groupId: 'a',
                episodeId: 'a-0',
                positionMs: 1234,
              ).toJson(),
            ),
          )
          .then(result.complete, onError: result.completeError);
    });
    for (var i = 0; i < 80 && !result.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(result.isCompleted, isTrue, reason: 'handoff should settle while test time advances');
    final receipt = await result.future;
    expect(receipt.phase, CompanionCommandPhase.started);
    expect(find.byKey(const Key('source-video-player')), findsOneWidget);
    expect(find.text('Old route'), findsNothing);
    expect(backendCreations, 1);
    await engine.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await settings.close();
    await _closeFixture(tester, startup, root);
  });

  testWidgets('failed candidate activation releases its route and leaves the old route intact', (tester) async {
    final root = (await tester.runAsync(() => Directory.systemTemp.createTemp('mg-read-companion-handoff-failure-')))!;
    final library = (await tester.runAsync(() => ContentLibrary.open(dataRoot: root)))!;
    final diagnostics = DiagnosticsManager(
      sink: const NoopDiagnosticEventSink(),
      registry: AppDiagnosticEvents.registry,
      source: DiagnosticSource.app,
    );
    final startup = AppStartupController(
      openResources: () async => AppStartupResources(contentLibrary: library),
      diagnostics: diagnostics,
    );
    await tester.runAsync(startup.start);
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    var backendDisposals = 0;
    final gateway = _Gateway(
      sources: <PluginSourceDescriptor>[
        PluginSourceDescriptor(
          id: 'tv-fixture',
          displayName: 'Fixture',
          contentKinds: const [PluginContentKind.video],
          pluginVersion: '1.0',
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourceContentGatewayProvider.overrideWithValue(gateway),
          appStartupControllerProvider.overrideWithValue(startup),
          appSettingsProvider.overrideWithValue(settings),
          diagnosticsManagerProvider.overrideWithValue(diagnostics),
          deviceIdentityStoreProvider.overrideWithValue(const _IdentityStore()),
          _testBackendFactoryProvider.overrideWithValue(() => _Backend(failPlay: true, onDispose: () => backendDisposals++)),
        ],
        child: MaterialApp(
          navigatorKey: appRootNavigatorKey,
          theme: AppTheme.light(),
          home: const Scaffold(body: Text('Old route')),
        ),
      ),
    );
    final container = ProviderScope.containerOf(tester.element(find.text('Old route')), listen: false);
    final engine = container.read(_handoffEngineProvider);
    engine.grantControl('phone-a');
    final result = Completer<CompanionReceipt>();
    await tester.runAsync(() async {
      engine
          .execute(
            'phone-a',
            CompanionCommand(
              id: 'failed-activation',
              hostEpoch: 'test-epoch',
              clientSeq: 1,
              controlGeneration: engine.controlGeneration,
              playbackGeneration: engine.playbackGeneration,
              deadlineMs: 5000,
              type: CompanionCommandType.handoff,
              arguments: const CompanionContentRef(
                pluginId: 'tv-fixture',
                pluginVersion: '1.0',
                contentId: 'show',
                title: 'Show',
                groupId: 'a',
                episodeId: 'a-0',
              ).toJson(),
            ),
          )
          .then(result.complete, onError: result.completeError);
    });
    final recoveryClock = Stopwatch()..start();
    while (!result.isCompleted && recoveryClock.elapsed < const Duration(seconds: 8)) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(
      result.isCompleted,
      isTrue,
      reason: 'disposed backends=$backendDisposals; candidate route=${appRootNavigatorKey.currentState?.canPop()}',
    );
    expect((await result.future).phase, CompanionCommandPhase.failed);
    await tester.pumpAndSettle();
    expect(find.text('Old route'), findsOneWidget);
    expect(appRootNavigatorKey.currentState?.canPop(), isFalse);
    expect(await tester.runAsync(() => library.readVideoHistory(videoHistorySourceKey('tv-fixture', 'show'))), isNull);
    expect(backendDisposals, 1);
    await engine.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await settings.close();
    await _closeFixture(tester, startup, root);
  });
}

/// Final player saves cross the fake widget clock and SQLite's real IO zone.
/// Pump both until shutdown completes rather than blocking either event loop.
Future<void> _closeFixture(WidgetTester tester, AppStartupController startup, Directory root) async {
  final closed = Completer<void>();
  closed.future.ignore();
  await tester.runAsync(() async {
    startup.close().then(closed.complete, onError: closed.completeError);
  });
  for (var i = 0; i < 300 && !closed.isCompleted; i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  }
  expect(closed.isCompleted, isTrue, reason: 'fixture must finish pending real IO and fake-zone callbacks');
  await closed.future;
  await tester.runAsync(() => root.delete(recursive: true));
}

final _handoffEngineProvider = Provider<CompanionCommandEngine>((ref) {
  final engine = CompanionCommandEngine(
    hostEpoch: 'test-epoch',
    nowMs: () => 1000,
    handler: (peerId, command, execution) async {
      try {
        await launchCompanionSourceVideo(
          ref,
          CompanionContentRef.fromJson(command.arguments),
          execution,
          backendFactory: ref.read(_testBackendFactoryProvider),
        );
        return CompanionReceipt(peerId: peerId, commandId: command.id, phase: CompanionCommandPhase.started);
      } on CompanionFailure catch (failure) {
        return CompanionReceipt(peerId: peerId, commandId: command.id, phase: CompanionCommandPhase.failed, code: failure.code);
      }
    },
  );
  ref.onDispose(engine.close);
  return engine;
});

final _testBackendFactoryProvider = Provider<VideoPlaybackBackendFactory?>((ref) => null);

final class _Gateway implements SourceContentGateway {
  _Gateway({this.sources = const <PluginSourceDescriptor>[]});

  final List<PluginSourceDescriptor> sources;

  @override
  Future<List<PluginSourceDescriptor>> listSources() async => sources;

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async => tvDetailFixture;

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async => tvCatalogFixture;

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) async =>
      PluginChapterContent(
        pluginId: pluginId,
        sourceName: 'Fixture',
        contentKind: PluginContentKind.video,
        chapterId: chapterId,
        title: 'Episode',
        updatedAt: null,
        text: null,
        pages: const [],
        media: PluginMediaResource(
          url: Uri.parse('http://127.0.0.1/video.m3u8'),
          resourceType: PluginMediaResourceType.hls,
          resourcePolicy: PluginMediaResourcePolicy.sessionOnly,
          expiresAt: null,
          mimeType: 'application/vnd.apple.mpegurl',
          headers: const {},
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _IdentityStore implements DeviceIdentityStore {
  const _IdentityStore();
  @override
  Future<LocalDeviceIdentity> loadOrCreateIdentity() async => const LocalDeviceIdentity(deviceId: 'tv-device', label: 'TV');
  @override
  Future<void> deletePeerSecret(String peerDeviceId) async {}
  @override
  Future<List<int>?> readPeerSecret(String peerDeviceId) async => null;
  @override
  Future<void> writePeerSecret(String peerDeviceId, List<int> secret) async {}
}

final class _Backend implements VideoPlaybackBackend {
  _Backend({this.failPlay = false, this.onDispose});
  final bool failPlay;
  final VoidCallback? onDispose;
  int _playCalls = 0;
  final ValueNotifier<VideoPlaybackBackendState> _state = ValueNotifier(const VideoPlaybackBackendState());
  @override
  ValueListenable<VideoPlaybackBackendState> get state => _state;
  @override
  Widget buildSurface({required BoxFit fit, Key? key}) => SizedBox.expand(key: key);
  @override
  Future<void> open(VideoEpisode episode, {required Duration initialPosition, required bool play}) async {
    _state.value = VideoPlaybackBackendState(playing: false, position: initialPosition, volume: _state.value.volume, firstFrameReady: true);
    if (play) await this.play();
  }

  @override
  Future<void> play() async {
    if (failPlay && ++_playCalls > 1) throw StateError('fake_activation_failure');
    _state.value = _state.value.copyWith(playing: true);
  }

  @override
  Future<void> pause() async => _state.value = _state.value.copyWith(playing: false);
  @override
  Future<void> seek(Duration position) async => _state.value = _state.value.copyWith(position: position);
  @override
  Future<void> setRate(double rate) async => _state.value = _state.value.copyWith(rate: rate);
  @override
  Future<void> setVolume(double volume) async => _state.value = _state.value.copyWith(volume: volume);
  @override
  Future<void> dispose() async {
    onDispose?.call();
    _state.dispose();
  }
}
