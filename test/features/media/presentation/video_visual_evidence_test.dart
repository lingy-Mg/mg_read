/// Production video view and settings; only transport and durable state are fake.
/// No MediaKit/native playback, network, database, or desktop window is started.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';

import '../../../support/visual_evidence.dart';

void main() {
  for (final (name, size) in [('portrait', const Size(390, 844)), ('desktop', const Size(1120, 720))]) {
    testWidgets('production video content and settings evidence $name', (tester) async {
      await loadVisualEvidenceFonts();
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = _VisualVideoBackend();
      await tester.pumpWidget(
        visualEvidenceHost(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.dark(),
            home: VideoPlayerView(
              contentId: 'visual-video',
              dataSource: const _VisualVideoSource(),
              stateStore: _VisualVideoStore(),
              backendFactory: () => backend,
              controlsAutoHideDelay: const Duration(hours: 1),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('video-player-controls')), findsOneWidget);
      expect(find.text('本地视频测试'), findsWidgets);
      expect(backend.openCalls, 1);
      await captureVisualEvidence(tester, 'video-$name-content-controls');
      await tester.tap(find.byKey(const Key('video-player-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      await captureVisualEvidence(tester, 'video-$name-settings');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(backend.disposed, isTrue);
    });
  }
}

class _VisualVideoSource implements VideoDataSource {
  const _VisualVideoSource();
  @override
  Future<VideoContent> load(String contentId) async => VideoContent(
    id: contentId,
    title: '本地视频测试',
    groups: [
      VideoEpisodeGroup(
        id: 'group-1',
        title: '第一组',
        episodes: [
          VideoEpisode(id: 'episode-1', title: '第一集', uri: 'https://example.invalid/one.mp4', durationHint: const Duration(minutes: 20)),
          VideoEpisode(id: 'episode-2', title: '第二集', uri: 'https://example.invalid/two.mp4', durationHint: const Duration(minutes: 24)),
        ],
      ),
    ],
  );
}

class _VisualVideoStore implements VideoPlaybackStateStore {
  @override
  Future<VideoPlaybackProgress?> load(String contentId) async => null;
  @override
  Future<void> save(VideoPlaybackProgress progress) async {}
}

class _VisualVideoBackend implements VideoPlaybackBackend {
  @override
  final ValueNotifier<VideoPlaybackBackendState> state = ValueNotifier<VideoPlaybackBackendState>(const VideoPlaybackBackendState());
  var openCalls = 0;
  var disposed = false;

  @override
  Widget buildSurface({required BoxFit fit, Key? key}) => ColoredBox(key: key, color: const Color(0xFF101820));
  @override
  Future<void> open(VideoEpisode episode, {required Duration initialPosition, required bool play}) async {
    openCalls++;
    state.value = VideoPlaybackBackendState(
      playing: play,
      position: initialPosition,
      duration: episode.durationHint!,
      firstFrameReady: true,
    );
  }

  @override
  Future<void> play() async => state.value = state.value.copyWith(playing: true);
  @override
  Future<void> pause() async => state.value = state.value.copyWith(playing: false);
  @override
  Future<void> seek(Duration position) async => state.value = state.value.copyWith(position: position);
  @override
  Future<void> setRate(double rate) async => state.value = state.value.copyWith(rate: rate);
  @override
  Future<void> setVolume(double volume) async => state.value = state.value.copyWith(volume: volume);
  @override
  Future<void> dispose() async {
    disposed = true;
    state.dispose();
  }
}
