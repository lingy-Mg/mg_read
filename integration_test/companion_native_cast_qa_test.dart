/// Native two-endpoint companion acceptance.
///
/// Run role=tv on the Windows LAN host first, then role=phone on the authorized
/// MuMu Android 12 client. MGREAD_COMPANION_QA_PHYSICAL=true also runs on an
/// isolated physical Android TV; network capabilities and discovery stay real.
/// TV reception uses the real PairedSyncHost,
/// CompanionController, encrypted direct LAN handshake and launchCompanionSourceVideo.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_companion_video.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_network_environment.dart';
import 'package:mg_read/features/lan_sync/application/lan_peer_service.dart';
import 'package:mg_read/features/lan_sync/application/paired_device_repository.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';
import 'package:mg_read/features/media/application/source_video_player_launcher.dart';
import 'package:mg_read/features/tv_companion/application/companion_controller.dart';
import 'package:mg_read/features/tv_companion/application/companion_media_host.dart';
import 'package:mg_read/features/tv_companion/data/companion_network.dart';
import 'package:mg_read/features/tv_companion/data/companion_repository.dart';
import 'package:mg_read/features/tv_companion/domain/companion_command.dart';
import 'support/companion_native_qa_server.dart';
import 'support/companion_qa_gateway.dart';
import '../test/core/settings/settings_testkit.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final role = const String.fromEnvironment('MGREAD_COMPANION_QA_ROLE');

  testWidgets('native companion TV receiver or Android phone handoff acceptance', (tester) async {
    expect(const String.fromEnvironment('MGREAD_APPLICATION_ID_SUFFIX'), anyOf('companionqa', 'companiontvqa'));
    expect(role, anyOf('tv', 'phone'), reason: 'Set MGREAD_COMPANION_QA_ROLE=tv or phone.');
    if (role == 'tv') {
      if (const bool.fromEnvironment('MGREAD_COMPANION_QA_PHYSICAL')) {
        expect(Platform.isAndroid, isTrue);
        await _runPhysicalTvReceiver(tester, binding);
      } else {
        expect(Platform.isWindows, isTrue, reason: 'TV receiver role belongs on the authorized Windows LAN host.');
        await _runTvReceiver(tester, binding);
      }
    } else {
      expect(Platform.isAndroid, isTrue, reason: 'Phone role belongs on the authorized MuMu Android 12 client.');
      await _runPhoneClient(tester, binding);
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}

Future<void> _runPhysicalTvReceiver(WidgetTester tester, IntegrationTestWidgetsFlutterBinding binding) async {
  final coordinator = Uri.parse('http://${const String.fromEnvironment('MGREAD_COMPANION_QA_HOST')}');
  final host = await _QaAppHost.create(
    role: 'tv',
    mediaUri: coordinator.replace(path: '/media.mp4'),
  );
  var publishing = false;
  Timer? publisher;
  try {
    await tester.pumpWidget(host.app);
    final container = ProviderScope.containerOf(tester.element(find.text('Companion QA receiver')), listen: false);
    final companion = container.read(companionControllerProvider);
    await companion.initialize();
    expect(isValidPairedDeviceId(companion.identity!.deviceId), isTrue);
    binding.reportData = {
      'role': 'physical-tv',
      'networkAvailable': await container.read(companionNetworkProvider).available(),
      'addresses': companion.localAddresses,
    };
    await companion.setTvMode(true);
    await container.read(deviceSyncControllerProvider.notifier).start();
    await _waitUntil(() => companion.hostPort != null, const Duration(seconds: 40));
    await _postJson(coordinator.replace(path: '/receiver-ready'), {
      'id': companion.identity!.deviceId,
      'label': companion.identity!.label,
      'port': companion.hostPort,
      'addresses': companion.localAddresses,
    });
    Future<void> publish() async {
      if (publishing) return;
      publishing = true;
      try {
        await _postJson(coordinator.replace(path: '/receiver-state'), {
          ...coordinatorState(companion, container),
          'durationMs': container.read(companionMediaHostProvider).active?.controller.snapshot.duration.inMilliseconds ?? 0,
          'controllers': companion.connectedControllerIds,
        });
      } finally {
        publishing = false;
      }
    }

    await publish();
    publisher = Timer.periodic(const Duration(milliseconds: 300), (_) => unawaited(publish()));
    await binding.convertFlutterSurfaceToImage();
    final done = _pollEndpoint(coordinator.replace(path: '/completion'), (value) => value['done'] == true, const Duration(minutes: 10));
    await _pumpUntil(tester, done, const Duration(minutes: 10));
    final state = coordinatorState(companion, container);
    expect(state['playing'], isTrue);
    expect(state['firstFrame'], isTrue);
    await binding.takeScreenshot('companion-physical-tv-playing');
    binding.reportData = {
      ...?binding.reportData,
      'role': 'physical-tv',
      'android': Platform.operatingSystemVersion,
      'addresses': companion.localAddresses,
      'finalReceiverState': state,
      'phoneReport': (await done)['report'],
    };
  } finally {
    publisher?.cancel();
    await tester.pumpWidget(const SizedBox.shrink());
    await host.close();
  }
}

Future<void> _runTvReceiver(WidgetTester tester, IntegrationTestWidgetsFlutterBinding binding) async {
  final hostAddress = const String.fromEnvironment('MGREAD_COMPANION_QA_WINDOWS_ADDRESS', defaultValue: '192.168.50.200');
  final host = await _QaAppHost.create(role: 'tv', mediaUri: Uri.parse('http://$hostAddress:41079/media.mp4'));
  final coordinator = await CompanionNativeQaServer.start();
  ProviderContainer? container;
  CompanionController? companion;
  try {
    await tester.pumpWidget(host.app);
    final activeContainer = ProviderScope.containerOf(tester.element(find.text('Companion QA receiver')), listen: false);
    final activeCompanion = activeContainer.read(companionControllerProvider);
    container = activeContainer;
    companion = activeCompanion;
    await activeCompanion.initialize();
    await activeCompanion.setTvMode(true);
    await activeContainer.read(deviceSyncControllerProvider.notifier).start();
    await _waitUntil(() => activeCompanion.hostPort != null, const Duration(seconds: 40));
    coordinator
      ..publishReady(deviceId: 'companion-qa-tv', label: 'Windows TV receiver', receiverPort: activeCompanion.hostPort!)
      ..setStateReader(() {
        final snapshot = activeContainer.read(companionMediaHostProvider).active?.controller.snapshot;
        return {
          'deviceId': 'companion-qa-tv',
          'receiverPort': activeCompanion.hostPort,
          'receiving': activeCompanion.receiverEnabled,
          'firstFrame': snapshot?.firstFrameReady ?? false,
          'playing': snapshot?.playing ?? false,
          'positionMs': snapshot?.position.inMilliseconds ?? 0,
          'durationMs': snapshot?.duration.inMilliseconds ?? 0,
          'episodeId': snapshot?.activeEpisodeId,
          'failure': snapshot?.failure?.code,
        };
      });
    await _waitUntil(
      () async => (await _getJson('http://127.0.0.1:41079/ready'))['port'] == activeCompanion.hostPort,
      const Duration(seconds: 5),
    );
    // Hold the real receiver process while the phone APK is built and its test is driven.
    final done = coordinator.done;
    await _pumpUntil(tester, done, const Duration(minutes: 8));
    final clientReport = await done;
    final report = <String, Object?>{
      'role': 'tv',
      'deviceId': 'companion-qa-tv',
      'receiverPort': activeCompanion.hostPort,
      'phoneReport': clientReport,
      'finalReceiverState': coordinatorState(activeCompanion, activeContainer),
      'acceptance': 'phone completed its UI cast, remote controls and disconnect assertions',
    };
    binding.reportData = {...?binding.reportData, ...report};
    await coordinator.writeReport(report);
    // ignore: avoid_print
    print('COMPANION_NATIVE_QA_REPORT ${jsonEncode(report)}');
  } on Object catch (error) {
    final report = <String, Object?>{
      'role': 'tv',
      'deviceId': 'companion-qa-tv',
      'error': error.toString(),
      'finalReceiverState': companion == null || container == null ? const {'ready': false} : coordinatorState(companion, container),
    };
    binding.reportData = {...?binding.reportData, ...report};
    await coordinator.writeReport(report);
    rethrow;
  } finally {
    await coordinator.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await host.close();
  }
}

Map<String, Object?> coordinatorState(CompanionController companion, ProviderContainer container) {
  final snapshot = container.read(companionMediaHostProvider).active?.controller.snapshot;
  return {
    'receiving': companion.receiverEnabled,
    'firstFrame': snapshot?.firstFrameReady ?? false,
    'playing': snapshot?.playing ?? false,
    'positionMs': snapshot?.position.inMilliseconds ?? 0,
    'episodeId': snapshot?.activeEpisodeId,
    'failure': snapshot?.failure?.code,
  };
}

Future<void> _runPhoneClient(WidgetTester tester, IntegrationTestWidgetsFlutterBinding binding) async {
  final coordinatorHost = const String.fromEnvironment('MGREAD_COMPANION_QA_HOST');
  expect(coordinatorHost, isNotEmpty, reason: 'Set MGREAD_COMPANION_QA_HOST=192.168.50.200:41079.');
  final coordinator = Uri.parse('http://$coordinatorHost');
  final ready = await _waitForReady(coordinator);
  final mediaUri = coordinator.replace(path: '/media.mp4');
  final host = await _QaAppHost.create(role: 'phone', mediaUri: mediaUri);
  try {
    await tester.pumpWidget(host.app);
    final home = find.text('Companion QA phone');
    final context = tester.element(home);
    final container = ProviderScope.containerOf(context, listen: false);
    final gateway = container.read(sourceContentGatewayProvider);
    final detail = await gateway.getDetail(pluginId: companionQaPluginId, id: companionQaContentId);
    final catalog = await gateway.getChapters(pluginId: companionQaPluginId, id: companionQaContentId);
    unawaited(
      openTransientSourceVideoPlayer(
        context,
        navigator: appRootNavigatorKey.currentState!,
        detail: detail,
        firstCatalogPage: catalog,
        chapter: catalog.items.firstWhere((episode) => episode.id == companionQaFirstEpisodeId),
        initialGroupId: companionQaGroupId,
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final phoneMedia = container.read(companionMediaHostProvider);
    await _waitUntil(
      () => phoneMedia.active?.controller.snapshot.firstFrameReady == true && phoneMedia.active!.controller.snapshot.playing,
      const Duration(seconds: 60),
    );
    final phoneBeforeCast = phoneMedia.active!.controller.snapshot.position.inMilliseconds;
    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('companion-phone-playing');

    // Drive the actual player-owned action and its manual endpoint picker.
    final cast = find.byKey(const Key('video-play-on-tv'));
    await tester.ensureVisible(cast);
    await tester.tap(cast);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('companion-phone-tv-picker');
    if (const bool.fromEnvironment('MGREAD_COMPANION_QA_PHYSICAL')) {
      final target = find.byKey(Key('companion-cast-device-${ready['id']}'));
      final discoveryClock = Stopwatch()..start();
      while (target.evaluate().isEmpty && discoveryClock.elapsed < const Duration(seconds: 40)) {
        await tester.pump(const Duration(milliseconds: 200));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(target, findsOneWidget, reason: 'The physical TV must be found by real LAN discovery, without a supplied address.');
      await binding.takeScreenshot('companion-phone-discovered-physical-tv');
      await tester.tap(target);
      await tester.pumpAndSettle();
    } else {
      final manualTarget = find.text('手动输入 TV 地址');
      expect(manualTarget, findsOneWidget);
      await tester.tap(manualTarget);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('companion-manual-address')), coordinatorHost.split(':').first);
      await tester.enterText(find.byKey(const Key('companion-manual-port')), '${ready['port']}');
      await tester.tap(find.byKey(const Key('companion-manual-connect')));
      await tester.pumpAndSettle();
    }
    final service = container.read(companionControllerProvider);
    Map<String, Object?> castState;
    try {
      castState = await _pollState(
        coordinator,
        (state) => state['firstFrame'] == true && state['playing'] == true,
        const Duration(seconds: 45),
      );
    } on Object {
      final diagnostic = {
        'connection': service.connectionStatus.name,
        'error': service.errorCode,
        'receipt': service.lastReceipt?.toJson(),
        'remoteState': service.remoteState?.toJson(),
      };
      // ignore: avoid_print
      print('COMPANION_CAST_DIAGNOSTIC ${jsonEncode(diagnostic)}');
      binding.reportData = {...?binding.reportData, 'castFailure': diagnostic};
      await binding.takeScreenshot('companion-phone-cast-failure');
      rethrow;
    }
    await _waitUntil(() => phoneMedia.active!.controller.snapshot.playing == false, const Duration(seconds: 20));
    expect(phoneMedia.active!.controller.snapshot.position.inMilliseconds, greaterThan(phoneBeforeCast));
    expect(castState['episodeId'], companionQaFirstEpisodeId);

    Future<Map<String, Object?>> command(CompanionCommandType type, {Map<String, Object?> arguments = const {}}) async {
      final receipt = await service.command(type, arguments: arguments);
      // ignore: avoid_print
      print('COMPANION_REMOTE_RECEIPT ${type.name} ${receipt.phase.name} ${receipt.code}');
      expect(receipt.phase, CompanionCommandPhase.applied, reason: 'Remote ${type.name} should apply.');
      return _pollState(coordinator, (_) => true, const Duration(seconds: 3));
    }

    await command(CompanionCommandType.pause);
    final paused = await _pollState(coordinator, (state) => state['playing'] == false, const Duration(seconds: 8));
    expect(paused['firstFrame'], isTrue);
    await command(CompanionCommandType.seek, arguments: {'positionMs': 12000});
    final sought = await _pollState(
      coordinator,
      (state) => ((state['positionMs'] as int) - 12000).abs() < 2500,
      const Duration(seconds: 8),
    );
    expect(sought['playing'], isFalse);
    await command(CompanionCommandType.play);
    final resumed = await _pollState(coordinator, (state) => state['playing'] == true, const Duration(seconds: 8));
    expect(resumed['episodeId'], companionQaFirstEpisodeId);
    await command(CompanionCommandType.nextEpisode);
    final next = await _pollState(
      coordinator,
      (state) => state['episodeId'] == companionQaNextEpisodeId && state['firstFrame'] == true,
      const Duration(seconds: 60),
    );
    expect(next['playing'], isTrue);
    final failure = await service.command(
      CompanionCommandType.selectEpisode,
      arguments: {'groupId': companionQaGroupId, 'episodeId': companionQaUnavailableEpisodeId},
    );
    expect(failure.phase, CompanionCommandPhase.failed);
    final retained = await _pollState(
      coordinator,
      (state) => state['episodeId'] == companionQaNextEpisodeId && state['playing'] == true,
      const Duration(seconds: 10),
    );
    expect(retained['failure'], isNull);
    await service.disconnect();
    final afterDisconnect = await _pollState(coordinator, (state) => state['playing'] == true, const Duration(seconds: 8));
    expect(afterDisconnect['episodeId'], companionQaNextEpisodeId);

    final report = <String, Object?>{
      'role': 'phone',
      'android': Platform.operatingSystemVersion,
      'coordinator': coordinatorHost,
      'receiver': ready,
      'automaticDiscovery': const bool.fromEnvironment('MGREAD_COMPANION_QA_PHYSICAL'),
      'cast': {'firstFrame': castState['firstFrame'], 'episodeId': castState['episodeId']},
      'pause': paused,
      'seek': sought,
      'play': resumed,
      'next': next,
      'unavailableEpisodeFailedRetainingCurrent':
          failure.phase == CompanionCommandPhase.failed && retained['episodeId'] == companionQaNextEpisodeId,
      'disconnectTvContinues': afterDisconnect['playing'] == true,
      'phonePausedAfterTvFirstFrame': !phoneMedia.active!.controller.snapshot.playing,
      'phonePositionMs': phoneMedia.active!.controller.snapshot.position.inMilliseconds,
    };
    binding.reportData = {...?binding.reportData, ...report};
    // ignore: avoid_print
    print('COMPANION_NATIVE_QA_REPORT ${jsonEncode(report)}');
    await _postJson(coordinator.replace(path: '/done'), report);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await host.close();
  }
}

Future<Map<String, Object?>> _waitForReady(Uri coordinator) async =>
    _pollEndpoint(coordinator.replace(path: '/ready'), (value) => value['port'] is int, const Duration(minutes: 8));

Future<Map<String, Object?>> _pollState(Uri coordinator, bool Function(Map<String, Object?>) reached, Duration timeout) =>
    _pollEndpoint(coordinator.replace(path: '/state'), reached, timeout);

Future<Map<String, Object?>> _pollEndpoint(Uri uri, bool Function(Map<String, Object?>) reached, Duration timeout) async {
  final clock = Stopwatch()..start();
  Object? lastError;
  while (clock.elapsed < timeout) {
    try {
      final value = await _getJson(uri.toString());
      if (reached(value)) return value;
    } on Object catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw TimeoutException('HTTP acceptance condition timed out: $uri; lastError=$lastError');
}

Future<Map<String, Object?>> _getJson(String url) async {
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  try {
    final response = await (await client.getUrl(Uri.parse(url))).close();
    final value = jsonDecode(await utf8.decoder.bind(response).join());
    if (response.statusCode != HttpStatus.ok || value is! Map<String, dynamic>) throw HttpException('Invalid JSON endpoint response: $url');
    return Map<String, Object?>.from(value);
  } finally {
    client.close(force: true);
  }
}

Future<void> _postJson(Uri uri, Map<String, Object?> value) async {
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  try {
    final request = await client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(value));
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode != HttpStatus.accepted) throw HttpException('Coordinator did not accept /done.');
  } finally {
    client.close(force: true);
  }
}

Future<void> _waitUntil(FutureOr<bool> Function() predicate, Duration timeout) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < timeout) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException('Native acceptance state timed out.');
}

Future<void> _pumpUntil(WidgetTester tester, Future<Object?> result, Duration timeout) async {
  var completed = false;
  Object? error;
  result.then(
    (_) => completed = true,
    onError: (Object value) {
      completed = true;
      error = value;
    },
  );
  final clock = Stopwatch()..start();
  while (!completed && clock.elapsed < timeout) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  if (!completed) throw TimeoutException('Android client did not finish within $timeout.');
  if (error != null) Error.throwWithStackTrace(error!, StackTrace.current);
}

final class _QaAppHost {
  _QaAppHost._(this.role, this.root, this.library, this.startup, this.settings, this.gateway, this.network);
  final String role;
  final Directory root;
  final ContentLibrary library;
  final AppStartupController startup;
  final AppSettingsManager settings;
  final CompanionQaGateway gateway;
  final _QaCompanionNetwork network;
  bool _closed = false;

  Widget get app => ProviderScope(
    overrides: [
      appStartupControllerProvider.overrideWithValue(startup),
      appSettingsProvider.overrideWithValue(settings),
      diagnosticsManagerProvider.overrideWithValue(_qaDiagnostics),
      sourceContentGatewayProvider.overrideWithValue(gateway),
      deviceIdentityStoreProvider.overrideWithValue(_QaIdentity(role)),
      pairedDeviceRepositoryProvider.overrideWithValue(_QaPairedDevices()),
      companionRepositoryProvider.overrideWithValue(MemoryCompanionRepository()),
      if (!const bool.fromEnvironment('MGREAD_COMPANION_QA_PHYSICAL')) ...[
        companionNetworkProvider.overrideWithValue(network),
        lanSyncNetworkEnvironmentProvider.overrideWithValue(const _QaLanEnvironment()),
      ],
      lanPeerServiceProvider.overrideWith((ref) => ref.read(companionControllerProvider)),
      companionHandoffLauncherProvider.overrideWith(
        (ref) =>
            (content, execution) => launchCompanionSourceVideo(ref, content, execution),
      ),
    ],
    child: MaterialApp(
      navigatorKey: appRootNavigatorKey,
      theme: AppTheme.light(),
      home: Scaffold(body: Center(child: Text(role == 'tv' ? 'Companion QA receiver' : 'Companion QA phone'))),
    ),
  );

  static Future<_QaAppHost> create({required String role, required Uri mediaUri}) async {
    final root = await Directory.systemTemp.createTemp('mgread-companion-native-$role-');
    final diagnostics = _qaDiagnostics;
    final library = await ContentLibrary.open(dataRoot: root, diagnostics: diagnostics);
    final startup = AppStartupController(
      openResources: () async => AppStartupResources(contentLibrary: library),
      diagnostics: diagnostics,
    );
    await startup.start();
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    await settings.initialize();
    if (const bool.fromEnvironment('MGREAD_COMPANION_QA_PHYSICAL')) await settings.set(AppSettingKeys.tvMode, role == 'tv');
    return _QaAppHost._(role, root, library, startup, settings, CompanionQaGateway(mediaUri), _QaCompanionNetwork(role));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await settings.close();
    await startup.close();
    await root.delete(recursive: true);
  }
}

final _qaDiagnostics = DiagnosticsManager(
  sink: const NoopDiagnosticEventSink(),
  registry: AppDiagnosticEvents.registry,
  source: DiagnosticSource.app,
);

final class _QaIdentity implements DeviceIdentityStore {
  const _QaIdentity(this.role);
  final String role;
  @override
  Future<LocalDeviceIdentity> loadOrCreateIdentity() async => LocalDeviceIdentity(
    deviceId: role == 'tv'
        ? (const bool.fromEnvironment('MGREAD_COMPANION_QA_PHYSICAL') ? 'companion-qa-tv-receiver' : 'companion-qa-tv')
        : 'companion-qa-phone',
    label: role == 'tv' ? (const bool.fromEnvironment('MGREAD_COMPANION_QA_PHYSICAL') ? 'MiTV companion QA' : 'Windows TV') : 'MuMu phone',
  );
  @override
  Future<void> deletePeerSecret(String peerDeviceId) async {}
  @override
  Future<List<int>?> readPeerSecret(String peerDeviceId) async => null;
  @override
  Future<void> writePeerSecret(String peerDeviceId, List<int> secret) async => throw StateError('Companion must not save pairing secrets.');
}

final class _QaPairedDevices implements PairedDeviceRepository {
  @override
  Future<List<PairedDevice>> list() async => const [];
  @override
  Future<PairedDevice?> read(String deviceId) async => null;
  @override
  Future<void> remove(String deviceId) async {}
  @override
  Future<void> upsert(PairedDevice device) async => throw StateError('Companion must not create sync pairing.');
}

final class _QaCompanionNetwork extends CompanionNetwork {
  const _QaCompanionNetwork(this.role);
  final String role;
  @override
  Future<bool> available() async => true;
  @override
  Future<bool> ensurePermission() async => true;
  @override
  Future<List<String>> addresses() async => [role == 'tv' ? '192.168.50.200' : '10.0.2.15'];
}

final class _QaLanEnvironment implements LanSyncNetworkEnvironment {
  const _QaLanEnvironment();
  @override
  Future<bool> isLocalNetworkAvailable() async => true;
}
