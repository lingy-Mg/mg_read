/// Timed remote seeking, including slow-backend coalescing and cancellation.
/// Fake widget time controls the gesture clock; no native player is created.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_video_player/src/ui/video_tv_seek_gesture.dart';

void main() {
  testWidgets('a short press seeks ten seconds once in either direction', (
    tester,
  ) async {
    var position = Duration.zero;
    final targets = <Duration>[];
    final gesture = VideoTvSeekGesture(
      readPosition: () => position,
      readDuration: () => const Duration(hours: 3),
      onActivity: () {},
      onSeek: (target) async {
        targets.add(target);
        position = target;
      },
    );
    addTearDown(gesture.dispose);
    gesture.press(1);
    await tester.pump(const Duration(milliseconds: 100));
    gesture.release(1);
    await tester.pump(const Duration(seconds: 5));
    expect(targets, [const Duration(seconds: 10)]);
    gesture.press(-1);
    gesture.release(-1);
    await tester.pump(const Duration(seconds: 5));
    expect(targets, [const Duration(seconds: 10), Duration.zero]);
  });

  testWidgets(
    'holding without repeat events accelerates and release stops all further advancement',
    (tester) async {
      var position = Duration.zero;
      final steps = <int>[];
      final gesture = VideoTvSeekGesture(
        readPosition: () => position,
        readDuration: () => const Duration(hours: 3),
        onActivity: () {},
        onSeek: (target) async {
          steps.add((target - position).inSeconds);
          position = target;
        },
      );
      addTearDown(gesture.dispose);
      gesture.press(1);
      for (var i = 0; i < 45; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(steps.toSet(), containsAll([10, 30, 60, 120]));
      expect(position, greaterThan(const Duration(minutes: 30)));
      gesture.release(1);
      final count = steps.length;
      await tester.pump(const Duration(seconds: 5));
      expect(steps.length, count);
    },
  );

  testWidgets('a slow backend receives only the current and final target', (
    tester,
  ) async {
    var position = Duration.zero;
    final targets = <Duration>[];
    final pending = Completer<void>();
    final gesture = VideoTvSeekGesture(
      readPosition: () => position,
      readDuration: () => const Duration(hours: 3),
      onActivity: () {},
      onSeek: (target) async {
        targets.add(target);
        if (targets.length == 1) await pending.future;
        position = target;
      },
    );
    addTearDown(gesture.dispose);
    gesture.press(1);
    await tester.pump(const Duration(seconds: 4));
    expect(targets, [const Duration(seconds: 10)]);
    gesture.release(1);
    pending.complete();
    await tester.pump();
    expect(targets.length, 2);
    expect(targets.last, greaterThan(const Duration(minutes: 3)));
    final selected = position;
    await tester.pump(const Duration(seconds: 5));
    expect(position, selected);
    expect(targets.length, 2);
  });

  testWidgets(
    'cancellation discards pending targets while an old seek finishes',
    (tester) async {
      var position = Duration.zero;
      final targets = <Duration>[];
      final pending = Completer<void>();
      final gesture = VideoTvSeekGesture(
        readPosition: () => position,
        readDuration: () => const Duration(hours: 3),
        onActivity: () {},
        onSeek: (target) async {
          targets.add(target);
          if (targets.length == 1) await pending.future;
          position = target;
        },
      );
      addTearDown(gesture.dispose);
      gesture.press(1);
      await tester.pump(const Duration(seconds: 4));
      gesture.cancel();
      pending.complete();
      await tester.pump(const Duration(seconds: 5));
      expect(targets, [const Duration(seconds: 10)]);
      gesture.press(-1);
      gesture.release(-1);
      await tester.pump();
      expect(targets.last, Duration.zero);
    },
  );

  testWidgets(
    'reversing direction resets acceleration and ignores the old key release',
    (tester) async {
      var position = const Duration(minutes: 30);
      final steps = <int>[];
      final gesture = VideoTvSeekGesture(
        readPosition: () => position,
        readDuration: () => const Duration(hours: 3),
        onActivity: () {},
        onSeek: (target) async {
          steps.add((target - position).inSeconds);
          position = target;
        },
      );
      addTearDown(gesture.dispose);
      gesture.press(1);
      await tester.pump(const Duration(seconds: 8));
      expect(steps.last, 120);
      gesture.press(-1);
      gesture.release(1);
      await tester.pump();
      expect(steps.last, -10);
      await tester.pump(const Duration(milliseconds: 650));
      expect(steps.last, -10);
      expect(gesture.isActive, isTrue);
      gesture.release(-1);
    },
  );

  testWidgets(
    'seeking clamps to both ends and does not keep issuing identical targets',
    (tester) async {
      const duration = Duration(hours: 3);
      var position = duration - const Duration(seconds: 5);
      final targets = <Duration>[];
      final gesture = VideoTvSeekGesture(
        readPosition: () => position,
        readDuration: () => duration,
        onActivity: () {},
        onSeek: (target) async {
          targets.add(target);
          position = target;
        },
      );
      addTearDown(gesture.dispose);
      gesture.press(1);
      await tester.pump(const Duration(seconds: 9));
      expect(targets, [duration]);
      expect(gesture.isActive, isFalse);
      position = const Duration(seconds: 5);
      gesture.press(-1);
      await tester.pump(const Duration(seconds: 9));
      expect(targets, [duration, Duration.zero]);
      expect(gesture.isActive, isFalse);
    },
  );
}
