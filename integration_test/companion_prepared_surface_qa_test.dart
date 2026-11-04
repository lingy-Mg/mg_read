/// Opt-in Android native prepared-session acceptance using the companion QA
/// coordinator's real byte-range sample. The candidate is mounted before
/// preparation, adopted without a second open, then a failing candidate must
/// leave the adopted player alive and advancing.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';
import 'support/companion_qa_source.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android Surface prepared backend adopts once and failed candidate keeps active playback', (tester) async {
    expect(const String.fromEnvironment('MGREAD_APPLICATION_ID_SUFFIX'), 'companionqa');
    expect(Platform.isAndroid, isTrue, reason: 'This acceptance must run on the authorized Android 12 MuMu client.');
    final host = const String.fromEnvironment('MGREAD_COMPANION_QA_HOST');
    expect(host, isNotEmpty, reason: 'Set MGREAD_COMPANION_QA_HOST to the Windows coordinator host:port.');
    final mediaUri = Uri.parse('http://$host/media.mp4');
    final source = CompanionQaVideoSource(mediaUri);
    VideoPlaybackBackend createBackend() => createMediaKitVideoPlaybackBackend(
      preferAndroidSurface: true,
      decoderMode: VideoDecoderMode.hardware,
      androidOutputMode: VideoAndroidOutputMode.directSurface,
    );
    final first = VideoPreparedSession(
      backendFactory: createBackend,
      dataSource: source,
      contentId: CompanionQaVideoSource.contentId,
      groupId: CompanionQaVideoSource.groupId,
      episodeId: CompanionQaVideoSource.firstEpisode,
      initialPosition: Duration.zero,
      timeout: const Duration(seconds: 40),
    );
    final controller = VideoPlayerController();
    final screenshotNames = <String>[];
    addTearDown(() async {
      first.dispose();
      controller.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 480, height: 270, child: first.buildSurface(key: const Key('companion-prepared-preview'))),
          ),
        ),
      ),
    );
    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await first.prepare();
    _report(binding, 'preparation', {'status': first.status.name, 'failure': first.failure?.code});
    expect(first.isReady, isTrue, reason: 'The mounted Android native Surface must produce the prepared first frame.');
    screenshotNames.add('companion-prepared-preview');
    await binding.takeScreenshot(screenshotNames.last);
    _report(binding, 'preparedPreview', {'status': first.status.name, 'nativeFirstFrame': first.isReady});

    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            VideoPlayerView(
              key: const Key('companion-adopted-player'),
              contentId: CompanionQaVideoSource.contentId,
              dataSource: source,
              stateStore: const _QaProgressStore(),
              preparedSession: first,
              controller: controller,
              backendFactory: createBackend,
              autoPlay: true,
              progressSaveThrottle: Duration.zero,
            ),
          ],
        ),
      ),
    );
    await _wait(tester, () => controller.snapshot.firstFrameReady && controller.snapshot.playing, const Duration(seconds: 20));
    final adoptedAt = controller.snapshot.position;
    await _wait(tester, () => controller.snapshot.position > adoptedAt + const Duration(seconds: 2), const Duration(seconds: 12));
    screenshotNames.add('companion-prepared-adopted');
    await binding.takeScreenshot(screenshotNames.last);
    _report(binding, 'adopted', {
      'firstFrame': controller.snapshot.firstFrameReady,
      'playing': controller.snapshot.playing,
      'positionMs': controller.snapshot.position.inMilliseconds,
      'adoptedWithoutReopen': true,
    });

    final failed = VideoPreparedSession(
      backendFactory: createBackend,
      dataSource: source,
      contentId: CompanionQaVideoSource.contentId,
      groupId: CompanionQaVideoSource.groupId,
      episodeId: CompanionQaVideoSource.unavailableEpisode,
      initialPosition: Duration.zero,
      timeout: const Duration(seconds: 20),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            VideoPlayerView(
              key: const Key('companion-adopted-player'),
              contentId: CompanionQaVideoSource.contentId,
              dataSource: source,
              stateStore: const _QaProgressStore(),
              preparedSession: first,
              controller: controller,
              backendFactory: createBackend,
              autoPlay: true,
              progressSaveThrottle: Duration.zero,
            ),
            Positioned(
              right: 8,
              bottom: 8,
              width: 240,
              height: 135,
              child: failed.buildSurface(key: const Key('companion-failed-preview')),
            ),
          ],
        ),
      ),
    );
    await failed.prepare();
    expect(failed.isReady, isFalse);
    expect(failed.status, VideoPreparationStatus.failed);
    final beforeRecoveryWait = controller.snapshot.position;
    await _wait(tester, () => controller.snapshot.position > beforeRecoveryWait, const Duration(seconds: 10));
    expect(controller.snapshot.firstFrameReady, isTrue);
    expect(controller.snapshot.failure, isNull);
    expect(controller.snapshot.playing, isTrue);
    screenshotNames.add('companion-prepared-failure-retained-player');
    await binding.takeScreenshot(screenshotNames.last);
    _report(binding, 'failedCandidateRetainedPlayback', {
      'candidateStatus': failed.status.name,
      'candidateFailure': failed.failure?.code,
      'activeFirstFrame': controller.snapshot.firstFrameReady,
      'activePlaying': controller.snapshot.playing,
      'activePositionMs': controller.snapshot.position.inMilliseconds,
      'screenshotNames': screenshotNames,
    });
    await tester.pumpWidget(const SizedBox.shrink());
    failed.dispose();
    await tester.pump(const Duration(milliseconds: 250));
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Future<void> _wait(WidgetTester tester, bool Function() predicate, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(predicate(), isTrue, reason: 'Timed out waiting for native playback state.');
}

void _report(IntegrationTestWidgetsFlutterBinding binding, String key, Map<String, Object?> value) {
  binding.reportData ??= <String, Object?>{};
  binding.reportData![key] = value;
  // ignore: avoid_print
  print('COMPANION_SURFACE_QA $key=$value');
}

final class _QaProgressStore implements VideoPlaybackStateStore {
  const _QaProgressStore();
  @override
  Future<VideoPlaybackProgress?> load(String contentId) async => null;
  @override
  Future<void> save(VideoPlaybackProgress progress) async {}
}
