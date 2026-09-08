/// Android audio-source and lifecycle acceptance on an already-authorized device.
///
/// This test uses the app-global playback service and real audio_service bridge.
/// It verifies the active TingChina source resolves a next chapter while no
/// playback UI exists and Flutter reports a background lifecycle state. Actual
/// Home/lock-screen interaction remains a manual device check.
library;

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

  testWidgets('Android service playback resolves the next chapter without player UI', (tester) async {
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
    final playback = service.open(
      SourceAudioPlaybackRequest(detail: detail, firstCatalogPage: catalog, chapter: playable.first, libraryItemId: null),
    );

    await _pumpUntil(tester, () => service.controller?.snapshot.status == AudioPlayerStatus.ready && service.controller!.snapshot.playing);
    final controller = service.controller!;
    expect(find.byType(AudioPlayerView), findsNothing);

    WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await controller.next();
    await _pumpUntil(tester, () => controller.snapshot.currentTrack?.id == playable[1].id);

    expect(controller.snapshot.playing, isTrue);
    expect(controller.snapshot.currentTrack?.id, playable[1].id);
    await service.stop();
    await playback;
    WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

final class _MemorySettingsStore implements SettingsStore {
  @override
  Future<List<SettingsDocument>> loadAll(Iterable<SettingsDocumentDefinition> documents) async => const <SettingsDocument>[];

  @override
  Future<List<SettingsDocument>> writeAll(List<SettingsDocument> documents) async => documents;

  @override
  Future<void> close() async {}
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition, {Duration timeout = const Duration(seconds: 90)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  expect(condition(), isTrue);
}

final class _RuntimeAudioGateway implements SourceContentGateway {
  const _RuntimeAudioGateway(this._runtime);

  final PluginRuntime _runtime;

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) =>
      _runtime.invoke(SourceDetailInvocation(pluginId: pluginId, id: id));

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) =>
      _runtime.invoke(SourceChaptersInvocation(pluginId: pluginId, id: id));

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) =>
      _runtime.invoke(SourceContentInvocation(pluginId: pluginId, id: id, chapterId: chapterId));

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
