/// Android audio-source and lifecycle acceptance on an already-authorized device.
///
/// This test uses the app-global playback service and real audio_service bridge.
/// It seeks to EOF with the next real source request deliberately held, then
/// verifies two automatic transitions with no playback UI or manual next call.
/// MGREAD_TEST_REQUIRE_SCREEN_OFF waits for an actual OS lifecycle transition;
/// the operator locks the device and separately records dumpsys power/media.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/media/application/source_audio_playback_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android service automatically continues after slow EOF loading', (tester) async {
    final runtime = PluginRuntime();
    final installed = await runtime.invoke(const InstalledPluginsInvocation());
    final source = installed.singleWhere((plugin) => plugin.id == 'org.mgread.tingchina-audio');
    expect(source.status, 'active');

    const pluginId = 'org.mgread.tingchina-audio';
    final gateway = _RuntimeAudioGateway(runtime);
    final search = await gateway.search(pluginId: pluginId, query: '有声', pageSize: 1);
    expect(search.items, isNotEmpty);
    final detail = await gateway.getDetail(pluginId: pluginId, id: search.items.first.id);
    final catalog = await gateway.getChapters(pluginId: pluginId, id: detail.summary.id);
    final playable = catalog.items.where((chapter) => chapter.isLocked != true).toList(growable: false);
    expect(playable.length, greaterThanOrEqualTo(3));
    final gates = <Completer<void>>[gateway.holdChapter(playable[1].id), gateway.holdChapter(playable[2].id)];

    final settings = AppSettingsManager(store: _MemorySettingsStore(), registry: AppSettingKeys.registry);
    await settings.initialize();
    addTearDown(settings.close);
    late WidgetRef rootRef;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSettingsProvider.overrideWithValue(settings), sourceContentGatewayProvider.overrideWithValue(gateway)],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              rootRef = ref;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    final service = rootRef.read(sourceAudioPlaybackServiceProvider.notifier);
    addTearDown(service.stop);
    final playback = service.open(
      SourceAudioPlaybackRequest(detail: detail, firstCatalogPage: catalog, chapter: playable.first, libraryItemId: null),
    );

    await _waitUntil(() => service.controller?.snapshot.status == AudioPlayerStatus.ready && service.controller!.snapshot.playing);
    final controller = service.controller!;
    expect(find.byType(AudioPlayerView), findsNothing);

    const requireScreenOff = bool.fromEnvironment('MGREAD_TEST_REQUIRE_SCREEN_OFF');
    debugPrint('AUDIO_EOF_READY requireScreenOff=$requireScreenOff');
    if (requireScreenOff) {
      // Never synthesize paused: physical acceptance requires the OS event.
      await _waitUntil(_isBackground, timeout: const Duration(minutes: 2));
    }
    for (var index = 0; index < gates.length; index++) {
      await _waitUntil(() => controller.snapshot.duration > const Duration(seconds: 2));
      final currentId = playable[index].id;
      expect(controller.snapshot.currentTrack?.id, currentId);
      await controller.seek(controller.snapshot.duration - const Duration(seconds: 1));
      await _waitUntil(() => controller.snapshot.completed);
      // A real multi-second resource delay must not cancel prefetch at EOF.
      await Future<void>.delayed(const Duration(seconds: 5));
      expect(controller.snapshot.currentTrack?.id, currentId);
      expect(controller.snapshot.resourceLoading, isTrue);
      expect(controller.snapshot.playbackDesired, isTrue);
      debugPrint('AUDIO_EOF_WAITING chapter=$index background=${_isBackground()}');
      gates[index].complete();
      await _waitUntil(
        () =>
            controller.snapshot.currentTrack?.id == playable[index + 1].id &&
            controller.snapshot.playing &&
            !controller.snapshot.resourceLoading &&
            controller.snapshot.position > const Duration(seconds: 1),
      );
      if (requireScreenOff) expect(_isBackground(), isTrue);
      expect(controller.snapshot.failure, isNull);
      debugPrint('AUDIO_EOF_ADVANCED chapter=${index + 1} background=${_isBackground()}');
    }
    await service.stop();
    await playback;
    debugPrint('AUDIO_EOF_FINISHED');
  }, timeout: const Timeout(Duration(minutes: 6)));
}

final class _MemorySettingsStore implements SettingsStore {
  @override
  Future<List<SettingsDocument>> loadAll(Iterable<SettingsDocumentDefinition> documents) async => const <SettingsDocument>[];

  @override
  Future<List<SettingsDocument>> writeAll(List<SettingsDocument> documents) async => documents;

  @override
  Future<void> close() async {}
}

bool _isBackground() => switch (WidgetsBinding.instance.lifecycleState) {
  AppLifecycleState.paused || AppLifecycleState.hidden => true,
  _ => false,
};

// Frame pumping stalls when the OS stops rendering during actual screen-off.
Future<void> _waitUntil(bool Function() condition, {Duration timeout = const Duration(seconds: 90)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(condition(), isTrue);
}

final class _RuntimeAudioGateway implements SourceContentGateway {
  _RuntimeAudioGateway(this._runtime);

  final PluginRuntime _runtime;
  final Map<String, Completer<void>> _chapterGates = <String, Completer<void>>{};

  Completer<void> holdChapter(String chapterId) => _chapterGates[chapterId] = Completer<void>();

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) =>
      _runtime.invoke(SourceDetailInvocation(pluginId: pluginId, id: id));

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) =>
      _runtime.invoke(SourceChaptersInvocation(pluginId: pluginId, id: id));

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) async {
    await _chapterGates[chapterId]?.future;
    return _runtime.invoke(SourceContentInvocation(pluginId: pluginId, id: id, chapterId: chapterId));
  }

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) =>
      _runtime.invoke(SourceSearchInvocation(pluginId: pluginId, query: query, cursor: cursor, pageSize: pageSize));

  @override
  Future<List<PluginSourceDescriptor>> listSources() => throw UnsupportedError('Not used by Android audio acceptance.');

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used by Android audio acceptance.');

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      throw UnsupportedError('Not used by Android audio acceptance.');
}
