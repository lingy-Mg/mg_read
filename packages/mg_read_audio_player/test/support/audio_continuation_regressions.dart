/// Slow-resource, EOF and sequential continuation regressions.
part of '../audio_player_background_recovery_test.dart';

void _continuationRegressions() {
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  for (final close in <bool>[false, true]) {
    test(
      'late EOF resource cannot resume after ${close ? 'close' : 'pause'}',
      () async {
        final harness = _Harness();
        final pending = Completer<List<AudioTrack>>();
        harness.source.pendingFollowing = pending;
        addTearDown(harness.close);
        await harness.session.initialize();
        await harness.controller.seek(const Duration(seconds: 99));
        harness.backend.emit(
          harness.backend.snapshot.copyWith(playing: false, completed: true),
        );
        if (close) {
          await harness.session.close();
        } else {
          await harness.controller.pause();
        }
        pending.complete(<AudioTrack>[_track('b')]);
        await settle();
        await settle();

        if (close) expect(harness.backend.appendedTrackIds, isEmpty);
        expect(harness.backend.jumpedIndices, isEmpty);
        expect(harness.backend.playCalls, 0);
        expect(harness.session.snapshot.playbackDesired, isFalse);
        expect(harness.session.snapshot.currentTrack?.id, 'a');
      },
    );
  }

  test('EOF at a later queue index advances to the appended chapter', () async {
    final harness = _Harness(
      initialTracks: <AudioTrack>[_track('a'), _track('b')],
    );
    final pending = Completer<List<AudioTrack>>();
    harness.source.pendingFollowing = pending;
    addTearDown(harness.close);
    await harness.session.initialize();
    await harness.controller.selectQueueEntry('b');
    harness.backend.jumpedIndices.clear();
    await harness.controller.seek(const Duration(seconds: 99));
    harness.backend.emit(
      harness.backend.snapshot.copyWith(
        playing: false,
        completed: true,
        position: const Duration(seconds: 100),
      ),
    );
    pending.complete(<AudioTrack>[_track('c')]);
    await settle();
    await settle();

    expect(harness.controller.snapshot.currentTrack?.id, 'c');
    expect(harness.backend.jumpedIndices, <int>[2]);
    expect(harness.controller.snapshot.playing, isTrue);
  });

  for (final background in <bool>[false, true]) {
    test(
      'slow EOF continuation survives recovery (background=$background)',
      () async {
        final harness = _Harness();
        final pending = Completer<List<AudioTrack>>();
        harness.source.pendingFollowing = pending;
        addTearDown(harness.close);
        await harness.session.initialize();
        await harness.controller.seek(const Duration(seconds: 99));
        if (background) {
          await harness.session.handleLifecycle(
            AudioPlayerLifecycleState.paused,
          );
        }
        harness.backend.emit(
          harness.backend.snapshot.copyWith(
            playing: false,
            completed: true,
            position: const Duration(seconds: 100),
          ),
        );

        final recovering = harness.controller.recover();
        // Cross both the recovery backoff and its former 500ms cancellation.
        await Future<void>.delayed(const Duration(milliseconds: 650));
        await recovering;
        expect(harness.source.followingCalls, 1);
        expect(harness.controller.snapshot.resourceLoading, isTrue);
        expect(harness.controller.snapshot.playbackDesired, isTrue);
        pending.complete(<AudioTrack>[_track('b')]);
        await settle();
        await settle();

        expect(harness.controller.snapshot.currentTrack?.id, 'b');
        expect(harness.controller.snapshot.playing, isTrue);
        expect(harness.controller.snapshot.resourceLoading, isFalse);
        expect(harness.backend.jumpedIndices, <int>[1]);
      },
    );
  }

  test('EOF during append advances without a recovery event', () async {
    final harness = _Harness();
    final gate = Completer<void>();
    harness.backend.appendGate = gate;
    addTearDown(harness.close);
    await harness.session.initialize();
    await harness.controller.seek(const Duration(seconds: 99));
    await settle();
    expect(harness.backend.appendedTrackIds, isEmpty);
    harness.backend.emit(
      harness.backend.snapshot.copyWith(
        playing: false,
        completed: true,
        position: const Duration(seconds: 100),
      ),
    );
    gate.complete();
    await settle();
    await settle();

    expect(harness.controller.snapshot.currentTrack?.id, 'b');
    expect(harness.controller.snapshot.playing, isTrue);
    expect(harness.controller.snapshot.resourceLoading, isFalse);
    expect(harness.backend.jumpedIndices, <int>[1]);
  });

  test(
    'waiting at EOF does not spend retries before a slow load fails',
    () async {
      final harness = _Harness();
      final pending = Completer<List<AudioTrack>>();
      harness.source.pendingFollowing = pending;
      addTearDown(harness.close);
      await harness.session.initialize();
      await harness.controller.seek(const Duration(seconds: 99));
      await harness.session.handleLifecycle(AudioPlayerLifecycleState.paused);
      harness.backend.emit(
        harness.backend.snapshot.copyWith(
          playing: false,
          completed: true,
          position: const Duration(seconds: 100),
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 650));
      pending.completeError(StateError('slow resource timeout'));
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(harness.source.followingCalls, 2);
      expect(harness.controller.snapshot.currentTrack?.id, 'b');
      expect(harness.controller.snapshot.playing, isTrue);
      expect(harness.controller.snapshot.failure, isNull);
    },
  );
}
