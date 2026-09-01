import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/src/api/contracts.dart';
import 'package:novel_reader_ui/src/api/models.dart';
import 'package:novel_reader_ui/src/core/chapter_access_coordinator.dart';

void main() {
  test(
    'merges and reuses chapter state coverage for one reader session',
    () async {
      final _RecordingChapterStateCapability capability =
          _RecordingChapterStateCapability();
      final ReaderChapterAccessCoordinator coordinator =
          ReaderChapterAccessCoordinator(
            bookId: 'book-1',
            capability: capability,
          );

      await coordinator.refresh(const <String>['chapter-1', 'chapter-2']);
      await coordinator.refresh(const <String>[
        'chapter-1',
        'chapter-2',
        'chapter-3',
      ]);
      await coordinator.refresh(const <String>[
        'chapter-1',
        'chapter-2',
        'chapter-3',
      ]);

      expect(capability.chapterRequests, <List<String>>[
        <String>['chapter-1', 'chapter-2'],
        <String>['chapter-3'],
      ]);
      expect(coordinator.snapshot.states.keys, <String>{
        'chapter-1',
        'chapter-2',
        'chapter-3',
      });

      await coordinator.refresh(const <String>['chapter-2'], force: true);

      expect(capability.chapterRequests, hasLength(3));
      expect(coordinator.snapshot.states, hasLength(3));
      expect(coordinator.snapshot.states['chapter-2']?.wordCount, 300);

      coordinator.dispose();
      expect(coordinator.snapshot.states, isEmpty);
      await coordinator.refresh(const <String>['chapter-1']);
      expect(capability.chapterRequests, hasLength(3));
    },
  );

  test(
    'failed automatic coverage waits for an explicit forced retry',
    () async {
      final _RecordingChapterStateCapability capability =
          _RecordingChapterStateCapability()..failure = StateError('offline');
      final ReaderChapterAccessCoordinator coordinator =
          ReaderChapterAccessCoordinator(
            bookId: 'book-1',
            capability: capability,
          );

      await coordinator.refresh(const <String>['chapter-1']);
      await coordinator.refresh(const <String>['chapter-1']);

      expect(capability.chapterRequests, hasLength(1));
      expect(coordinator.snapshot.failure, isA<StateError>());

      capability.failure = null;
      await coordinator.refresh(const <String>['chapter-1'], force: true);

      expect(capability.chapterRequests, hasLength(2));
      expect(coordinator.snapshot.failure, isNull);
      expect(
        coordinator.snapshot.states['chapter-1']?.availability,
        ReaderChapterAvailability.downloaded,
      );
      coordinator.dispose();
    },
  );

  test('deduplicates overlapping chapter state requests in flight', () async {
    final Completer<void> release = Completer<void>();
    final _RecordingChapterStateCapability capability =
        _RecordingChapterStateCapability(release: release.future);
    final ReaderChapterAccessCoordinator coordinator =
        ReaderChapterAccessCoordinator(
          bookId: 'book-1',
          capability: capability,
        );

    final Future<void> first = coordinator.refresh(const <String>[
      'chapter-1',
      'chapter-2',
    ]);
    final Future<void> duplicate = coordinator.refresh(const <String>[
      'chapter-1',
      'chapter-2',
    ]);

    expect(capability.chapterRequests, hasLength(1));
    release.complete();
    await Future.wait<void>(<Future<void>>[first, duplicate]);

    expect(capability.chapterRequests, hasLength(1));
    expect(coordinator.snapshot.states, hasLength(2));
    coordinator.dispose();
  });

  test(
    'forced refresh waits for an overlapping lookup before rechecking',
    () async {
      final Completer<void> release = Completer<void>();
      final _RecordingChapterStateCapability capability =
          _RecordingChapterStateCapability(release: release.future);
      final ReaderChapterAccessCoordinator coordinator =
          ReaderChapterAccessCoordinator(
            bookId: 'book-1',
            capability: capability,
          );

      final Future<void> first = coordinator.refresh(const <String>[
        'chapter-1',
      ]);
      final Future<void> forced = coordinator.refresh(const <String>[
        'chapter-1',
      ], force: true);

      expect(capability.chapterRequests, <List<String>>[
        <String>['chapter-1'],
      ]);
      release.complete();
      await Future.wait<void>(<Future<void>>[first, forced]);

      expect(capability.chapterRequests, <List<String>>[
        <String>['chapter-1'],
        <String>['chapter-1'],
      ]);
      coordinator.dispose();
    },
  );

  test('rebinding starts a fresh book-scoped session cache', () async {
    final _RecordingChapterStateCapability capability =
        _RecordingChapterStateCapability();
    final ReaderChapterAccessCoordinator coordinator =
        ReaderChapterAccessCoordinator(
          bookId: 'book-1',
          capability: capability,
        );
    await coordinator.refresh(const <String>['chapter-1']);

    coordinator.rebind(bookId: 'book-2', capability: capability);

    expect(coordinator.snapshot.states, isEmpty);
    await coordinator.refresh(const <String>['chapter-1']);
    expect(capability.bookRequests, <String>['book-1', 'book-2']);
    coordinator.dispose();
  });
}

final class _RecordingChapterStateCapability
    implements ReaderChapterStateCapability {
  _RecordingChapterStateCapability({this.release});

  final Future<void>? release;
  final List<String> bookRequests = <String>[];
  final List<List<String>> chapterRequests = <List<String>>[];
  Object? failure;

  @override
  Future<Map<String, ReaderChapterState>> loadChapterStates(
    String bookId,
    List<String> chapterIds,
  ) async {
    bookRequests.add(bookId);
    chapterRequests.add(List<String>.of(chapterIds));
    if (release != null) await release;
    if (failure case final Object error) throw error;
    final int wordCount = chapterRequests.length * 100;
    return <String, ReaderChapterState>{
      for (final String chapterId in chapterIds)
        chapterId: ReaderChapterState(
          chapterId: chapterId,
          availability: ReaderChapterAvailability.downloaded,
          wordCount: wordCount,
        ),
    };
  }

  @override
  Future<void> markRead(String bookId, String chapterId) async {}
}
