/// Explicitly authorized Android acceptance for the production Bilibili flow.
/// Updates only the supplied source artifact, preserves application data, and
/// uses Finder interactions through discovery, details and the real audio host.
/// The runner must restore the normal app APK after this test entrypoint exits.
library;

import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/main.dart' as app;
import 'package:mg_read/app/app.dart';
import 'package:mg_read/features/discovery/application/discovery_page_controller.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/media/application/source_audio_playback_service.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const pluginId = 'org.mgread.bilibili-audio';
  const videoId = 'bvid:BV1tGe36YEap';

  testWidgets('phone resolves a pasted URL from discovery and plays its independent audio', (tester) async {
    const artifactPath = String.fromEnvironment('MGREAD_TEST_ARTIFACT_PATH');
    expect(artifactPath, isNotEmpty);
    await AndroidNodeRuntimeSettings.instance.initialize();
    final runtime = PluginRuntime();
    final before = await runtime.invoke(const InstalledPluginsInvocation());
    final bytes = await File(artifactPath).readAsBytes();
    final artifact = PluginTransferArtifact(
      bytes: bytes.length,
      checksum: getCrc32(bytes).toRadixString(16).padLeft(8, '0'),
      pluginId: pluginId,
      version: '1.0.3',
      format: PluginArtifactFormat.singleFile,
      provenance: PluginArtifactProvenance.installed,
      developmentFingerprint: null,
      developmentRevision: null,
    );
    final imported = await runtime.importPluginArtifacts(
      [(artifact: artifact, bytes: Stream.value(bytes))],
      forceUpgradePluginIds: {pluginId},
    );
    expect(imported.single.status, PluginTransferImportStatus.installed);
    final installed = await runtime.invoke(const InstalledPluginsInvocation());
    final source = installed.singleWhere((item) => item.id == pluginId);
    if (!source.enabled) await runtime.invoke(const SetPluginEnabledInvocation(pluginId: pluginId, enabled: true));
    expect(installed.length, greaterThanOrEqualTo(before.length));
    debugPrint('BILIBILI_DEVICE_IMPORT_PASS version=1.0.3 installed=${installed.length}');

    await app.main([]);
    await _wait(tester, () => find.byKey(const Key('app-nav-discover')).hitTestable().evaluate().isNotEmpty);
    await tester.pump(const Duration(seconds: 1));
    final container = ProviderScope.containerOf(tester.element(find.byType(MgReadApp)), listen: false);
    await tester.tap(find.byKey(const Key('app-nav-discover')).hitTestable());
    await _wait(tester, () => container.read(discoveryPageControllerProvider).sources.any((item) => item.id == pluginId));
    await container.read(discoveryPageControllerProvider.notifier).selectSource(pluginId);
    final input = find.byKey(const Key('discovery-input-video-link'));
    final submit = find.byKey(const Key('discovery-input-submit-video-link'));
    final error = find.byKey(const Key('discovery-input-error-video-link'));
    await _wait(tester, () => input.evaluate().isNotEmpty);
    expect(find.byKey(const Key('bilibili-url-play-action')), findsNothing);
    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('bilibili-discovery-input');

    await tester.enterText(input, 'https://www.bilibili.com/video/BV-invalid');
    await tester.pump();
    await tester.tap(submit);
    await _wait(tester, () => error.evaluate().isNotEmpty);
    expect(find.textContaining('确认已安装'), findsNothing);
    debugPrint('BILIBILI_DEVICE_INVALID_INPUT_PASS');

    await tester.enterText(input, 'https://www.bilibili.com/video/BV1tGe36YEap/?_from=333.337.search-card.all.click');
    await tester.pump();
    await tester.tap(submit);
    final result = find.byKey(const Key('discovery-input-result-video-link-bvid:BV1tGe36YEap'));
    await _wait(tester, () => result.evaluate().isNotEmpty || error.evaluate().isNotEmpty);
    expect(error, findsNothing);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.ensureVisible(result);
    await binding.takeScreenshot('bilibili-discovery-resolved');
    await tester.tap(result);
    await _wait(tester, () => find.byKey(const Key('source-detail-loaded')).evaluate().isNotEmpty);
    final catalog = await container.read(sourceContentGatewayProvider).getChapters(pluginId: pluginId, id: videoId);
    expect(catalog.items, hasLength(34));
    expect(catalog.items.last.title, '711-760完结');
    await tester.pump(const Duration(milliseconds: 500));
    final first = find.byKey(ValueKey('source-detail-episode-${catalog.groups.first.id}-${catalog.items.first.id}'));
    await tester.scrollUntilVisible(
      first.hitTestable(),
      300,
      scrollable: find.descendant(of: find.byKey(const Key('source-content-detail-sheet')), matching: find.byType(Scrollable)).first,
      maxScrolls: 35,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await _wait(tester, () => first.hitTestable().evaluate().isNotEmpty);
    await binding.takeScreenshot('bilibili-detail-catalog');
    await tester.tap(first.hitTestable());
    final service = container.read(sourceAudioPlaybackServiceProvider.notifier);
    try {
      await _wait(tester, () => service.controller?.snapshot.playing == true);
      final controller = service.controller!;
      final initial = controller.snapshot.position;
      await _wait(tester, () => controller.snapshot.position > initial + const Duration(seconds: 3));
      expect(controller.snapshot.failure, isNull);
      expect(controller.snapshot.duration, greaterThan(Duration.zero));
      await binding.takeScreenshot('bilibili-audio-playing');
      final status = await runtime.invoke(const RuntimeStatusInvocation());
      binding.reportData = {
        ...?binding.reportData,
        'pluginVersion': '1.0.3',
        'runtimeKind': status.runtimeKind,
        'installedBefore': before.length,
        'installedAfter': installed.length,
        'inlineDiscoveryInput': true,
        'invalidInputRecovered': true,
        'videoId': videoId,
        'chapters': catalog.items.length,
        'lastChapter': catalog.items.last.title,
        'playingChapter': controller.snapshot.currentTrack?.id,
        'playing': controller.snapshot.playing,
        'positionMs': controller.snapshot.position.inMilliseconds,
        'durationMs': controller.snapshot.duration.inMilliseconds,
      };
      debugPrint(
        'BILIBILI_DEVICE_PLAYBACK_PASS backend=${status.runtimeKind} chapters=34 positionMs=${controller.snapshot.position.inMilliseconds}',
      );
    } finally {
      await service.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}

Future<void> _wait(WidgetTester tester, bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 100));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  expect(condition(), isTrue, reason: 'Timed out waiting for the production device flow.');
}
