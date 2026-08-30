/// App-global audio ownership tests.
///
/// These tests keep media I/O outside the coordinator and verify only session
/// replacement, presentation, and the pause-before-stop conflict boundary.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/media/application/source_audio_playback_coordinator.dart';

void main() {
  test('minimizes and restores one session until it is stopped', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final coordinator = container.read(sourceAudioPlaybackCoordinatorProvider.notifier);

    final playback = coordinator.open(_request('chapter-1'));
    await Future<void>.delayed(Duration.zero);
    final sessionId = container.read(sourceAudioPlaybackCoordinatorProvider).sessionId!;

    coordinator.minimize(sessionId);
    expect(container.read(sourceAudioPlaybackCoordinatorProvider).presentation, SourceAudioPresentation.minimized);

    coordinator.expand();
    expect(container.read(sourceAudioPlaybackCoordinatorProvider).presentation, SourceAudioPresentation.expanded);

    await coordinator.stop();
    await playback;
    expect(container.read(sourceAudioPlaybackCoordinatorProvider).isActive, isFalse);
  });

  test('stops audible output before retiring a session', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final coordinator = container.read(sourceAudioPlaybackCoordinatorProvider.notifier);
    final playback = coordinator.open(_request('chapter-2'));
    await Future<void>.delayed(Duration.zero);
    final state = container.read(sourceAudioPlaybackCoordinatorProvider);
    final controller = _RecordingAudioPlayerController();
    expect(coordinator.attachController(state.sessionId!, controller), isTrue);

    await coordinator.stop();
    await playback;

    expect(controller.pauseCalls, 1);
    controller.dispose();
  });
}

final class _RecordingAudioPlayerController extends AudioPlayerController {
  int pauseCalls = 0;

  @override
  Future<void> pause() async {
    pauseCalls++;
  }
}

SourceAudioPlaybackRequest _request(String chapterId) {
  final chapter = PluginChapterSummary(
    id: chapterId,
    title: chapterId,
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
    author: null,
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
