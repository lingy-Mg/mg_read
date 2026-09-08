/// System audio-focus lifecycle tests for transient video playback.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/media/application/source_video_audio_session_controller.dart';

void main() {
  test('activates only while playing and deactivates on pause', () async {
    final platform = _FakeAudioSessionPlatform();
    final controller = SourceVideoAudioSessionController.withPlatform(platform, () async {});

    await controller.setPlaybackActive(true);
    await controller.setPlaybackActive(false);

    expect(platform.activeRequests, <bool>[true, false]);
    await controller.restoreAndClose();
    expect(platform.closed, isTrue);
  });

  test('interruption and unplugged-headphone request pause', () async {
    final platform = _FakeAudioSessionPlatform();
    var pauses = 0;
    final controller = SourceVideoAudioSessionController.withPlatform(platform, () async => pauses++);

    await controller.setPlaybackActive(true);
    platform.requestPause();
    await Future<void>.delayed(Duration.zero);

    expect(pauses, 1);
    await controller.restoreAndClose();
  });

  test('denied audio focus requests a safe pause', () async {
    final platform = _FakeAudioSessionPlatform()..acceptActivation = false;
    var pauses = 0;
    final controller = SourceVideoAudioSessionController.withPlatform(platform, () async => pauses++);

    await controller.setPlaybackActive(true);
    await Future<void>.delayed(Duration.zero);

    expect(pauses, 1);
    await controller.restoreAndClose();
  });

  test('close releases active focus and ignores later requests', () async {
    final platform = _FakeAudioSessionPlatform();
    final controller = SourceVideoAudioSessionController.withPlatform(platform, () async {});

    await controller.setPlaybackActive(true);
    await controller.restoreAndClose();
    await controller.setPlaybackActive(true);

    expect(platform.activeRequests, <bool>[true, false]);
    expect(platform.closed, isTrue);
  });

  test('pause repairs a partially failed focus acquisition', () async {
    final platform = _FakeAudioSessionPlatform()..failNextActivation = true;
    final controller = SourceVideoAudioSessionController.withPlatform(platform, () async {});

    await expectLater(controller.setPlaybackActive(true), throwsStateError);
    await controller.setPlaybackActive(false);

    expect(platform.activeRequests, <bool>[true, false]);
    await controller.restoreAndClose();
  });
}

final class _FakeAudioSessionPlatform implements SourceVideoAudioSessionPlatform {
  final StreamController<void> _pauseRequests = StreamController<void>.broadcast(sync: true);
  final List<bool> activeRequests = <bool>[];
  bool acceptActivation = true;
  bool failNextActivation = false;
  bool closed = false;

  @override
  Stream<void> get pauseRequests => _pauseRequests.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> setActive(bool active) async {
    activeRequests.add(active);
    if (active && failNextActivation) {
      failNextActivation = false;
      throw StateError('partial activation failure');
    }
    return !active || acceptActivation;
  }

  void requestPause() => _pauseRequests.add(null);

  @override
  Future<void> close() async {
    closed = true;
    await _pauseRequests.close();
  }
}
