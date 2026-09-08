/// App-global audio service ownership tests without page or platform I/O.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/media/application/source_audio_playback_service.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('keeps loading and controlling playback with no player UI mounted', () async {
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    await settings.initialize();
    addTearDown(settings.close);
    final request = _request();
    final gateway = _AudioGateway(request);
    final backend = _RecordingBackend();
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWithValue(settings),
        sourceContentGatewayProvider.overrideWithValue(gateway),
        sourceAudioPlaybackBackendFactoryProvider.overrideWithValue(() => backend),
      ],
    );
    addTearDown(container.dispose);
    final service = container.read(sourceAudioPlaybackServiceProvider.notifier);

    final playback = service.open(request);
    await _waitUntil(() => service.controller?.snapshot.status == AudioPlayerStatus.ready && service.controller!.snapshot.playing);
    final originalController = service.controller;

    service.minimize(container.read(sourceAudioPlaybackServiceProvider).sessionId!);
    await originalController!.next();

    expect(gateway.loadedChapterIds, <String>['chapter-1', 'chapter-2']);
    expect(service.controller, same(originalController));
    expect(backend.openCalls, 2);
    expect(backend.disposeCalls, 0);

    service.expand();
    expect(service.controller, same(originalController));
    await service.stop();
    await playback;
    expect(backend.disposeCalls, 1);
    expect(container.read(sourceAudioPlaybackServiceProvider).isActive, isFalse);
  });

  test('stops the old engine before replacing the playback request', () async {
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    await settings.initialize();
    addTearDown(settings.close);
    final request = _request();
    final gateway = _AudioGateway(request);
    final backends = <_RecordingBackend>[];
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWithValue(settings),
        sourceContentGatewayProvider.overrideWithValue(gateway),
        sourceAudioPlaybackBackendFactoryProvider.overrideWithValue(() {
          final backend = _RecordingBackend();
          backends.add(backend);
          return backend;
        }),
      ],
    );
    addTearDown(container.dispose);
    final service = container.read(sourceAudioPlaybackServiceProvider.notifier);

    final firstPlayback = service.open(request);
    await _waitUntil(() => service.controller?.isAttached ?? false);
    final secondPlayback = service.open(
      SourceAudioPlaybackRequest(
        detail: request.detail,
        firstCatalogPage: request.firstCatalogPage,
        chapter: request.firstCatalogPage.items[1],
        libraryItemId: null,
      ),
    );
    await firstPlayback;
    await _waitUntil(() => backends.length == 2);

    expect(backends.first.pauseCalls, greaterThanOrEqualTo(1));
    expect(backends.first.disposeCalls, 1);
    await service.stop();
    await secondPlayback;
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

final class _AudioGateway implements SourceContentGateway {
  const _AudioGateway(this.request);

  final SourceAudioPlaybackRequest request;
  static final List<String> _empty = <String>[];
  List<String> get loadedChapterIds => _loadedChapterIds[this] ?? _empty;
  static final Expando<List<String>> _loadedChapterIds = Expando<List<String>>('loadedChapterIds');

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async => request.detail;

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async => request.firstCatalogPage;

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) async {
    (_loadedChapterIds[this] ??= <String>[]).add(chapterId);
    return PluginChapterContent(
      pluginId: pluginId,
      sourceName: '测试源',
      contentKind: PluginContentKind.audio,
      chapterId: chapterId,
      title: chapterId,
      updatedAt: null,
      text: null,
      pages: const <PluginMangaPage>[],
      media: PluginMediaResource(
        url: Uri.parse('https://example.test/$chapterId.mp3'),
        resourceType: PluginMediaResourceType.audio,
        resourcePolicy: PluginMediaResourcePolicy.sessionOnly,
        expiresAt: null,
        mimeType: 'audio/mpeg',
        headers: const <String, String>{},
      ),
    );
  }

  @override
  Future<List<PluginSourceDescriptor>> listSources() => throw UnimplementedError();

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnimplementedError();

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();
}

final class _RecordingBackend implements AudioPlaybackBackend {
  final StreamController<AudioPlaybackBackendSnapshot> _events = StreamController<AudioPlaybackBackendSnapshot>.broadcast(sync: true);
  AudioPlaybackBackendSnapshot _snapshot = const AudioPlaybackBackendSnapshot(duration: Duration(minutes: 2));
  int openCalls = 0;
  int pauseCalls = 0;
  int disposeCalls = 0;

  @override
  AudioPlaybackBackendSnapshot get snapshot => _snapshot;

  @override
  Stream<AudioPlaybackBackendSnapshot> get snapshots => _events.stream;

  void _emit(AudioPlaybackBackendSnapshot value) {
    _snapshot = value;
    _events.add(value);
  }

  @override
  Future<void> open(List<AudioTrack> tracks, {required int initialIndex, bool play = false}) async {
    openCalls++;
    _emit(AudioPlaybackBackendSnapshot(currentIndex: initialIndex, duration: const Duration(minutes: 2), playing: play));
  }

  @override
  Future<void> append(List<AudioTrack> tracks) async {}

  @override
  Future<void> play() async => _emit(_snapshot.copyWith(playing: true));

  @override
  Future<void> pause() async {
    pauseCalls++;
    _emit(_snapshot.copyWith(playing: false));
  }

  @override
  Future<void> seek(Duration position) async => _emit(_snapshot.copyWith(position: position));

  @override
  Future<void> setRate(double rate) async => _emit(_snapshot.copyWith(rate: rate));

  @override
  Future<void> setVolume(double volume) async => _emit(_snapshot.copyWith(volume: volume));

  @override
  Future<void> previous() async {}

  @override
  Future<void> next() async {}

  @override
  Future<void> jump(int index) async => _emit(_snapshot.copyWith(currentIndex: index, position: Duration.zero));

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await _events.close();
  }
}

SourceAudioPlaybackRequest _request() {
  final chapters = <PluginChapterSummary>[
    for (var index = 1; index <= 2; index++)
      PluginChapterSummary(
        id: 'chapter-$index',
        title: '第$index章',
        order: index - 1,
        url: null,
        volumeTitle: null,
        wordCount: null,
        updatedAt: null,
        isLocked: false,
        attributes: const <PluginContentAttribute>[],
      ),
  ];
  final summary = PluginContentSummary(
    id: 'audio-1',
    title: '测试音频',
    contentKind: PluginContentKind.audio,
    author: '播讲者',
    url: null,
    coverUrl: null,
    description: null,
    language: 'zh-CN',
    status: PluginContentStatus.unknown,
    access: PluginAccessKind.unknown,
    wordCount: null,
    chapterCount: chapters.length,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: const <String>[],
    tags: const <String>[],
    attributes: const <PluginContentAttribute>[],
  );
  return SourceAudioPlaybackRequest(
    detail: PluginContentDetail(pluginId: 'test.audio', sourceName: '测试源', summary: summary, aliases: const <String>[], catalogUrl: null),
    firstCatalogPage: PluginChaptersResult(pluginId: 'test.audio', sourceName: '测试源', items: chapters),
    chapter: chapters.first,
    libraryItemId: null,
  );
}
