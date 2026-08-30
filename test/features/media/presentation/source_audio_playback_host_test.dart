/// Global audio host behavior tests with an I/O-free playback backend.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/media/application/source_audio_playback_coordinator.dart';
import 'package:mg_read/features/media/presentation/source_audio_playback_host.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  testWidgets('remembers continue choice and restores from the mini player', (tester) async {
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    await settings.initialize();
    addTearDown(settings.close);
    final request = _request();
    final backend = _FakeAudioBackend();
    final backButtonDispatcher = RootBackButtonDispatcher();
    Future<bool> routerFallback() async => false;
    backButtonDispatcher.addCallback(routerFallback);
    late WidgetRef rootRef;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(settings),
          sourceContentGatewayProvider.overrideWithValue(_AudioGateway(request)),
          sourceAudioPlaybackBackendFactoryProvider.overrideWithValue(() => backend),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: Center(child: Text('详情页'))),
          builder: (context, child) => Consumer(
            builder: (context, ref, _) {
              rootRef = ref;
              return Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  child ?? const SizedBox.shrink(),
                  SourceAudioPlaybackOverlay(backButtonDispatcher: backButtonDispatcher),
                ],
              );
            },
          ),
        ),
      ),
    );

    final playback = rootRef.read(sourceAudioPlaybackCoordinatorProvider.notifier).open(request);
    await _pumpUntil(
      tester,
      () =>
          find.byKey(const Key('audio-back')).evaluate().isNotEmpty &&
          find.byKey(const Key('media-entry-cover-transition')).evaluate().isEmpty,
    );

    await tester.tap(find.byKey(const Key('audio-back')));
    await _pumpUntil(tester, () => find.byKey(const Key('audio-background-exit-dialog')).evaluate().isNotEmpty);
    await tester.tap(find.byKey(const Key('audio-background-remember-choice')));
    await tester.tap(find.byKey(const Key('audio-background-continue')));
    await _pumpUntil(tester, () => find.byKey(const Key('source-audio-mini-player')).evaluate().isNotEmpty);

    expect(settings.get(AppSettingKeys.audioExitBehavior), 'continue');
    expect(find.text('详情页'), findsOneWidget);

    await tester.tap(find.byKey(const Key('source-audio-mini-player')));
    await _pumpUntil(tester, () => find.byKey(const Key('audio-back')).evaluate().isNotEmpty);

    final Future<bool> backHandled = backButtonDispatcher.invokeCallback(Future<bool>.value(false));
    await tester.pump();
    expect(await backHandled, isTrue);
    await _pumpUntil(tester, () => find.byKey(const Key('source-audio-mini-player')).evaluate().isNotEmpty);
    expect(find.byKey(const Key('audio-background-exit-dialog')), findsNothing);

    await tester.tap(find.byKey(const Key('source-audio-mini-stop')));
    await _pumpUntil(tester, () => find.byKey(const Key('source-audio-mini-player')).evaluate().isEmpty);
    await playback;
    expect(find.byKey(const Key('source-audio-mini-player')), findsNothing);
    expect(backend.pauseCalls, greaterThanOrEqualTo(1));
    await settings.flush();
    await tester.pump(const Duration(milliseconds: 350));
    backButtonDispatcher.removeCallback(routerFallback);
  });
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var index = 0; index < 80 && !condition(); index++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(condition(), isTrue);
}

final class _AudioGateway implements SourceContentGateway {
  const _AudioGateway(this.request);

  final SourceAudioPlaybackRequest request;

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async => request.detail;

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async => request.firstCatalogPage;

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) async =>
      PluginChapterContent(
        pluginId: pluginId,
        sourceName: '测试源',
        contentKind: PluginContentKind.audio,
        chapterId: chapterId,
        title: '第一章',
        updatedAt: null,
        text: null,
        pages: const <PluginMangaPage>[],
        media: PluginMediaResource(
          url: Uri.parse('https://example.test/audio.mp3'),
          resourceType: PluginMediaResourceType.audio,
          resourcePolicy: PluginMediaResourcePolicy.sessionOnly,
          expiresAt: null,
          mimeType: 'audio/mpeg',
          headers: const <String, String>{},
        ),
      );

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

final class _FakeAudioBackend implements AudioPlaybackBackend {
  final StreamController<AudioPlaybackBackendSnapshot> _states = StreamController<AudioPlaybackBackendSnapshot>.broadcast(sync: true);
  AudioPlaybackBackendSnapshot _snapshot = const AudioPlaybackBackendSnapshot(duration: Duration(minutes: 2));
  int pauseCalls = 0;

  @override
  AudioPlaybackBackendSnapshot get snapshot => _snapshot;

  @override
  Stream<AudioPlaybackBackendSnapshot> get snapshots => _states.stream;

  void _emit(AudioPlaybackBackendSnapshot value) {
    _snapshot = value;
    _states.add(value);
  }

  @override
  Future<void> open(List<AudioTrack> tracks, {required int initialIndex, bool play = false}) async {
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
  Future<void> dispose() => _states.close();
}

SourceAudioPlaybackRequest _request() {
  final chapter = PluginChapterSummary(
    id: 'chapter-1',
    title: '第一章',
    order: 0,
    url: null,
    volumeTitle: null,
    wordCount: null,
    updatedAt: null,
    isLocked: false,
    attributes: const <PluginContentAttribute>[],
  );
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
    chapterCount: 1,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: const <String>[],
    tags: const <String>[],
    attributes: const <PluginContentAttribute>[],
  );
  return SourceAudioPlaybackRequest(
    detail: PluginContentDetail(pluginId: 'test.audio', sourceName: '测试源', summary: summary, aliases: const <String>[], catalogUrl: null),
    firstCatalogPage: PluginChaptersResult(pluginId: 'test.audio', sourceName: '测试源', items: <PluginChapterSummary>[chapter]),
    chapter: chapter,
    libraryItemId: null,
  );
}
