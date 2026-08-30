/// Android audio-source and lifecycle acceptance on an already-authorized device.
///
/// This test uses Finder/runtime APIs only. It verifies the active TingChina
/// source resolves a bounded next-chapter queue while Flutter reports a
/// background lifecycle state; actual Home/lock-screen interaction remains a
/// manual device check because this suite must not control the emulator.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/media/application/source_audio_playlist_data_source.dart';
import 'package:mg_read/features/media/application/transient_source_audio_playback_state_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android TingChina playback autoplays and resolves the next chapter while paused',
    (tester) async {
      final runtime = PluginRuntime();
      final installed = await runtime.invoke(const InstalledPluginsInvocation());
      final source = installed.singleWhere(
        (plugin) => plugin.id == 'org.mgread.tingchina-audio',
      );
      expect(source.status, 'active');

      const pluginId = 'org.mgread.tingchina-audio';
      final gateway = _RuntimeAudioGateway(runtime);
      final search = await gateway.search(
        pluginId: pluginId,
        query: '有声',
        pageSize: 1,
      );
      expect(search.items, isNotEmpty);
      final detail = await gateway.getDetail(
        pluginId: pluginId,
        id: search.items.first.id,
      );
      final catalog = await gateway.getChapters(
        pluginId: pluginId,
        id: detail.summary.id,
      );
      final playable = catalog.items
          .where((chapter) => chapter.isLocked != true)
          .toList(growable: false);
      expect(playable.length, greaterThanOrEqualTo(3));

      final controller = AudioPlayerController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: AudioPlayerView(
            collectionId: detail.summary.id,
            dataSource: SourceAudioPlaylistDataSource(
              gateway: gateway,
              pluginId: pluginId,
              initialTrackId: playable.first.id,
              initialDetail: detail,
              initialCatalog: catalog,
            ),
            stateStore: TransientSourceAudioPlaybackStateStore(
              collectionId: detail.summary.id,
              initialTrackId: playable.first.id,
            ),
            controller: controller,
          ),
        ),
      );

      await _pumpUntil(
        tester,
        () =>
            controller.snapshot.status == AudioPlayerStatus.ready &&
            controller.snapshot.playing,
      );
      expect(controller.snapshot.queue, hasLength(2));

      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await controller.next();
      await _pumpUntil(
        tester,
        () => controller.snapshot.queue.length >= 3,
      );

      expect(controller.snapshot.playing, isTrue);
      expect(controller.snapshot.currentIndex, 1);
      expect(controller.snapshot.queue[2].id, playable[2].id);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 90),
}) async {
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
  Future<PluginContentDetail> getDetail({
    required String pluginId,
    required String id,
  }) => _runtime.invoke(SourceDetailInvocation(pluginId: pluginId, id: id));

  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
  }) => _runtime.invoke(SourceChaptersInvocation(pluginId: pluginId, id: id));

  @override
  Future<PluginChapterContent> getContent({
    required String pluginId,
    required String id,
    required String chapterId,
  }) => _runtime.invoke(
    SourceContentInvocation(
      pluginId: pluginId,
      id: id,
      chapterId: chapterId,
    ),
  );

  @override
  Future<PluginSearchResult> search({
    required String pluginId,
    required String query,
    String? cursor,
    int pageSize = 20,
  }) => _runtime.invoke(
    SourceSearchInvocation(
      pluginId: pluginId,
      query: query,
      cursor: cursor,
      pageSize: pageSize,
    ),
  );

  @override
  Future<List<PluginSourceDescriptor>> listSources() =>
      throw UnsupportedError('Not used by Android audio acceptance.');

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used by Android audio acceptance.');

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({
    required String pluginId,
    String? cursor,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used by Android audio acceptance.');
}
