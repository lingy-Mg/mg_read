import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/library/application/library_refresh_queue.dart';

void main() {
  test('caps total and source concurrency and prioritizes manual work', () async {
    final queue = LibraryRefreshQueue();
    final active = <String, Completer<bool>>{};
    final started = <String>[];
    final futures = <Future<bool>>[];
    void add(String id, String source, {bool automatic = true}) {
      futures.add(
        queue.run(source, () {
          started.add(id);
          final gate = Completer<bool>();
          active[id] = gate;
          return gate.future;
        }, automatic: automatic),
      );
    }

    add('a1', 'a');
    add('a2', 'a');
    add('a3', 'a');
    add('b1', 'b');
    add('b2', 'b');
    add('c1', 'c');
    add('manual', 'a', automatic: false);
    expect(started, ['a1', 'a2', 'b1', 'b2']);
    active.remove('a1')!.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(started.last, 'manual');
    while (active.isNotEmpty) {
      final batch = active.values.toList();
      active.clear();
      for (final gate in batch) {
        gate.complete(true);
      }
      await Future<void>.delayed(Duration.zero);
    }
    expect(await Future.wait(futures), everyElement(isTrue));
    expect(started.toSet(), hasLength(7));
  });

  test('backgrounded queued jobs skip while manual work still runs', () async {
    final queue = LibraryRefreshQueue();
    final gate = Completer<bool>();
    var foreground = true;
    final a = queue.run('source', () => gate.future, automatic: true);
    final b = queue.run('source', () => gate.future, automatic: true);
    final skipped = queue.run('source', () async => fail('must not start'), automatic: true, mayStart: () => foreground);
    final expectation = expectLater(skipped, throwsA(isA<LibraryRefreshSkipped>()));
    foreground = false;
    final manual = queue.run('source', () async => true, automatic: false);
    gate.complete(true);
    await Future.wait([a, b, manual]);
    await expectation;
  });
}
