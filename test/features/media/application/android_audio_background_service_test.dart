/// Android media-session projection tests without platform or network I/O.
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';

import 'package:mg_read/features/media/application/android_audio_background_service.dart';

void main() {
  test('projects the full catalog and routes system transport commands', () async {
    final controller = _RecordingAudioController(
      AudioPlayerSnapshot(
        status: AudioPlayerStatus.ready,
        collectionId: 'book',
        collectionTitle: '有声书',
        creator: '播讲者',
        queue: <AudioTrack>[
          AudioTrack(
            id: 'chapter-2',
            title: '第二章',
            collectionTitle: '有声书',
            creator: '播讲者',
            resource: Uri.parse('https://example.test/chapter-2.mp3'),
          ),
        ],
        queueEntries: const <AudioQueueEntry>[
          AudioQueueEntry(id: 'chapter-1', title: '第一章'),
          AudioQueueEntry(id: 'chapter-2', title: '第二章'),
          AudioQueueEntry(id: 'chapter-locked', title: '付费章', isLocked: true),
          AudioQueueEntry(id: 'chapter-3', title: '第三章'),
        ],
        playing: true,
        position: const Duration(seconds: 12),
        duration: const Duration(minutes: 3),
      ),
    );
    addTearDown(controller.dispose);
    final handler = MgReadAudioHandler();
    var systemStopCalls = 0;
    final feedback = <AudioSystemCommandFeedback>[];

    await handler.attach(
      controller,
      synchronizeFocus: (_) async {},
      onSystemStop: () async => systemStopCalls++,
      commandFeedback: (value) async => feedback.add(value),
    );

    expect(handler.queue.value.map((item) => item.id), <String>['chapter-1', 'chapter-2', 'chapter-3']);
    expect(handler.mediaItem.value?.id, 'chapter-2');
    expect(handler.mediaItem.value?.duration, const Duration(minutes: 3));
    expect(handler.playbackState.value.queueIndex, 1);
    expect(handler.playbackState.value.controls.map((control) => control.action), <MediaAction>[
      MediaAction.skipToPrevious,
      MediaAction.pause,
      MediaAction.skipToNext,
      MediaAction.stop,
    ]);

    await handler.skipToPrevious();
    await handler.skipToNext();
    await handler.skipToQueueItem(2);
    await handler.skipToQueueItem(3);

    expect(controller.previousCalls, 1);
    expect(controller.nextCalls, 1);
    expect(controller.selectedTrackIds, <String>['chapter-3']);
    expect(feedback, <AudioSystemCommandFeedback>[
      AudioSystemCommandFeedback.accepted,
      AudioSystemCommandFeedback.accepted,
      AudioSystemCommandFeedback.accepted,
    ]);

    await handler.stop();

    expect(controller.pauseCalls, 1);
    expect(systemStopCalls, 1);
    expect(feedback.last, AudioSystemCommandFeedback.accepted);
    expect(handler.queue.value, isEmpty);
    expect(handler.mediaItem.value, isNull);
  });

  test('only publishes adjacent controls that can act', () async {
    final controller = _RecordingAudioController(
      AudioPlayerSnapshot(
        status: AudioPlayerStatus.ready,
        queue: <AudioTrack>[AudioTrack(id: 'only', title: '唯一章节', resource: Uri.parse('https://example.test/only.mp3'))],
      ),
    );
    addTearDown(controller.dispose);
    final handler = MgReadAudioHandler();

    await handler.attach(controller, synchronizeFocus: (_) async {}, onSystemStop: () async {});

    expect(handler.playbackState.value.controls.map((control) => control.action), <MediaAction>[MediaAction.play, MediaAction.stop]);
    expect(handler.playbackState.value.androidCompactActionIndices, <int>[0]);

    await handler.detach(controller);
  });

  test('screen-on recovery reaches only the attached controller', () async {
    final controller = _RecordingAudioController(AudioPlayerSnapshot.initial());
    addTearDown(controller.dispose);
    final handler = MgReadAudioHandler();

    await handler.recoverActiveController();
    await handler.attach(controller, synchronizeFocus: (_) async {}, onSystemStop: () async {});
    await handler.recoverActiveController();
    await handler.detach(controller);
    await handler.recoverActiveController();

    expect(controller.recoverCalls, 1);
  });

  test('error play retries while loading and queue boundaries are rejected', () async {
    final feedback = <AudioSystemCommandFeedback>[];
    final controller = _RecordingAudioController(
      AudioPlayerSnapshot(
        status: AudioPlayerStatus.error,
        queue: <AudioTrack>[AudioTrack(id: 'only', title: '唯一章节', resource: Uri.parse('https://example.test/only.mp3'))],
      ),
    );
    addTearDown(controller.dispose);
    final handler = MgReadAudioHandler();
    await handler.attach(
      controller,
      synchronizeFocus: (_) async {},
      onSystemStop: () async {},
      commandFeedback: (value) async => feedback.add(value),
    );

    await handler.play();
    controller.currentSnapshot = AudioPlayerSnapshot.initial();
    await handler.play();
    controller.currentSnapshot = AudioPlayerSnapshot(status: AudioPlayerStatus.ready, queue: controller.currentSnapshot.queue);
    await handler.skipToNext();

    expect(controller.retryCalls, 1);
    expect(feedback, <AudioSystemCommandFeedback>[
      AudioSystemCommandFeedback.accepted,
      AudioSystemCommandFeedback.unavailable,
      AudioSystemCommandFeedback.unavailable,
    ]);
  });

  test('duplicate next commands do not issue duplicate resource requests', () async {
    final gate = Completer<void>();
    final feedback = <AudioSystemCommandFeedback>[];
    final controller = _RecordingAudioController(
      AudioPlayerSnapshot(
        status: AudioPlayerStatus.ready,
        queue: <AudioTrack>[AudioTrack(id: 'a', title: 'a', resource: Uri.parse('https://example.test/a.mp3'))],
        queueEntries: const <AudioQueueEntry>[
          AudioQueueEntry(id: 'a', title: 'a'),
          AudioQueueEntry(id: 'b', title: 'b'),
        ],
      ),
    )..nextGate = gate;
    addTearDown(controller.dispose);
    final handler = MgReadAudioHandler();
    await handler.attach(
      controller,
      synchronizeFocus: (_) async {},
      onSystemStop: () async {},
      commandFeedback: (value) async => feedback.add(value),
    );

    final first = handler.skipToNext();
    await Future<void>.delayed(Duration.zero);
    await handler.skipToNext();
    gate.complete();
    await first;

    expect(controller.nextCalls, 1);
    expect(
      feedback,
      containsAll(<AudioSystemCommandFeedback>[AudioSystemCommandFeedback.accepted, AudioSystemCommandFeedback.unavailable]),
    );
  });
}

final class _RecordingAudioController extends AudioPlayerController {
  _RecordingAudioController(this.currentSnapshot);

  AudioPlayerSnapshot currentSnapshot;
  int pauseCalls = 0;
  int previousCalls = 0;
  int nextCalls = 0;
  int recoverCalls = 0;
  int retryCalls = 0;
  Completer<void>? nextGate;
  final List<String> selectedTrackIds = <String>[];

  @override
  AudioPlayerSnapshot get snapshot => currentSnapshot;

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> previous() async {
    previousCalls++;
  }

  @override
  Future<void> next() async {
    nextCalls++;
    await nextGate?.future;
  }

  @override
  Future<void> retry() async {
    retryCalls++;
  }

  @override
  Future<void> recover() async {
    recoverCalls++;
  }

  @override
  Future<void> selectQueueEntry(String trackId) async {
    selectedTrackIds.add(trackId);
  }
}
