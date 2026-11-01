/// Opt-in TV acceptance with the production native video backend and audio focus.
/// Installs only as tvdecodeqa; downloads a public Flutter sample into the test
/// app's temporary directory and checks autoplay across fresh episode sessions.
/// Reports native state without pressing play or changing production app data.
/// MGREAD_TV_CAPTURE_HOLD_SECONDS optionally holds a paused frame for ADB capture.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mg_read/features/media/application/source_video_audio_session_controller.dart';
import 'package:mg_read/features/media/application/source_video_playback_platform_controller.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native TV autoplay survives first surface and a second episode', (tester) async {
    expect(const String.fromEnvironment('MGREAD_APPLICATION_ID_SUFFIX'), 'tvdecodeqa');
    final preferAndroidSurface = await readSourceVideoDirectSurfacePreference();
    if (const bool.fromEnvironment('MGREAD_TV_NATIVE_SURFACE')) expect(preferAndroidSurface, isTrue);
    debugPrint('TV_NATIVE_OUTPUT directSurface=$preferAndroidSurface');
    final sampleUri = Uri.parse(
      const String.fromEnvironment(
        'MGREAD_TV_SAMPLE_URL',
        defaultValue: 'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4',
      ),
    );
    final directory = await Directory.systemTemp.createTemp('mgread-tv-native-');
    addTearDown(() => directory.delete(recursive: true));
    final sample = File('${directory.path}/sample.mp4');
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(sampleUri)).close();
      expect(response.statusCode, HttpStatus.ok);
      await response.pipe(sample.openWrite());
    } finally {
      client.close(force: true);
    }
    final controller = VideoPlayerController();
    final observer = _NativeObserver(controller);
    addTearDown(() async {
      await observer.audio.restoreAndClose();
      controller.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: VideoPlayerView(
          tvMode: true,
          contentId: 'tv-native',
          dataSource: _NativeSource(sample.uri.toString()),
          stateStore: _NativeStore(),
          controller: controller,
          observer: observer,
          backendFactory: () => createMediaKitVideoPlaybackBackend(preferAndroidSurface: preferAndroidSurface),
        ),
      ),
    );
    try {
      for (final episode in ['first', 'second']) {
        if (episode == 'second') {
          unawaited(controller.selectEpisode('default', episode));
        }
        await _wait(
          tester,
          () =>
              (controller.snapshot.activeEpisodeId == episode &&
                  controller.snapshot.firstFrameReady &&
                  controller.snapshot.position > const Duration(seconds: 2)) ||
              controller.snapshot.failure != null,
        );
        final snapshot = controller.snapshot;
        debugPrint(
          'TV_NATIVE_RESULT episode=$episode playing=${snapshot.playing} '
          'positionMs=${snapshot.position.inMilliseconds} failure=${snapshot.failure?.code}',
        );
        expect(snapshot.failure, isNull);
        expect(snapshot.playing, isTrue, reason: 'No manual play command should be required.');
        expect(snapshot.position, greaterThan(const Duration(seconds: 2)));
        expect(observer.firstFrames, greaterThanOrEqualTo(episode == 'first' ? 1 : 2));
        binding.reportData ??= {};
        binding.reportData![episode] = {
          'playing': snapshot.playing,
          'positionMs': snapshot.position.inMilliseconds,
          'firstFrames': observer.firstFrames,
          'activeChanges': observer.activeChanges.toList(),
        };
      }
      await controller.pause();
      unawaited(controller.toggleControls());
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.snapshot.playing, isFalse);
      debugPrint('TV_NATIVE_CAPTURE_READY');
      const holdSeconds = int.fromEnvironment('MGREAD_TV_CAPTURE_HOLD_SECONDS');
      for (var tick = 0; tick < holdSeconds.clamp(0, 30) * 10; tick++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(controller.snapshot.playing, isFalse, reason: 'An explicit pause must remain paused.');
      unawaited(controller.selectEpisode('default', 'unavailable'));
      await _wait(tester, () => controller.snapshot.failure != null);
      expect(controller.snapshot.status, VideoPlayerStatus.failure);
      binding.reportData!['unavailableResourceFailed'] = true;
      debugPrint('TV_NATIVE_UNAVAILABLE_RESOURCE_FAILED');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

final class _NativeObserver extends VideoPlayerObserver {
  _NativeObserver(this.controller) {
    audio = SourceVideoAudioSessionController(
      onPauseRequested: () async {
        debugPrint('TV_NATIVE_AUDIO_PAUSE_REQUEST');
        await controller.pause();
      },
    );
  }
  final VideoPlayerController controller;
  late final SourceVideoAudioSessionController audio;
  int firstFrames = 0;
  final List<bool> activeChanges = [];

  @override
  void onFirstFrame(VideoPlayerSnapshot snapshot) => firstFrames++;

  @override
  Future<void> onPlaybackActiveChanged(bool active) async {
    debugPrint('TV_NATIVE_ACTIVE active=$active');
    activeChanges.add(active);
    await audio.setPlaybackActive(active);
  }
}

final class _NativeSource implements VideoDataSource {
  _NativeSource(this.uri);
  final String uri;

  @override
  Future<VideoContent> load(String contentId) async => VideoContent(
    id: contentId,
    title: 'Native TV playback',
    groups: [
      VideoEpisodeGroup(
        id: 'default',
        title: 'Samples',
        episodes: [
          for (final id in ['first', 'second']) VideoEpisode(id: id, title: id, uri: uri),
          VideoEpisode(id: 'unavailable', title: 'Unavailable', uri: '$uri.missing'),
        ],
      ),
    ],
  );
}

final class _NativeStore implements VideoPlaybackStateStore {
  @override
  Future<VideoPlaybackProgress?> load(String contentId) async => null;

  @override
  Future<void> save(VideoPlaybackProgress progress) async {}
}
