import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/tv_companion/application/companion_command_engine.dart';
import 'package:mg_read/features/tv_companion/domain/companion_command.dart';

void main() {
  group('CompanionCommand protocol', () {
    test('round trips and fingerprints object keys canonically', () {
      final first = _command(
        'a',
        1,
        args: {
          'z': 2,
          'nested': {'b': 1, 'a': 2},
        },
      );
      final second = _command(
        'a',
        1,
        args: {
          'nested': {'a': 2, 'b': 1},
          'z': 2,
        },
      );
      expect(first.fingerprint(), second.fingerprint());
      expect(CompanionCommand.fromJson(first.toJson()).type, CompanionCommandType.play);
    });

    test('rejects unknown fields, commands and oversized arguments', () {
      expect(() => CompanionCommand.fromJson({..._command('a', 1).toJson(), 'unknown': true}), throwsFormatException);
      expect(() => CompanionCommand.fromJson({..._command('a', 1).toJson(), 'type': 'runAnything'}), throwsFormatException);
      expect(
        () => CompanionCommand.fromJson({
          ..._command('a', 1).toJson(),
          'arguments': {'large': 'x' * 17000},
        }),
        throwsFormatException,
      );
    });
  });

  group('CompanionCommandEngine', () {
    late int now;
    late CompanionCommandEngine engine;
    late List<String> effects;

    setUp(() {
      now = 1000;
      effects = [];
      engine = CompanionCommandEngine(
        hostEpoch: 'boot-1',
        nowMs: () => now,
        leaseDuration: const Duration(seconds: 2),
        handler: (peer, command, context) async {
          context.ensureCurrent();
          effects.add('${command.id}:${command.type.name}');
          return CompanionReceipt(peerId: peer, commandId: command.id, phase: CompanionCommandPhase.applied);
        },
      );
    });

    tearDown(() async => engine.close());

    test('same id retry shares work; changed payload conflicts', () async {
      await _acquire(engine, 'phone');
      final command = _command('once', 2, generation: engine.controlGeneration);
      final first = engine.execute('phone', command);
      final retry = engine.execute('phone', command);
      final different = engine.execute('phone', _command('once', 2, generation: engine.controlGeneration, args: {'positionMs': 2}));
      expect((await Future.wait([first, retry])).first.phase, CompanionCommandPhase.applied);
      expect((await different).code, 'command_id_conflict');
      expect(effects, ['once:play']);
      expect(engine.receiptFor('phone', 'once')?.phase, CompanionCommandPhase.applied);
    });

    test('rejects reversed sequence numbers even before older command runs', () async {
      await _acquire(engine, 'phone');
      final high = engine.execute('phone', _command('high', 3, generation: engine.controlGeneration));
      final low = await engine.execute('phone', _command('low', 2, generation: engine.controlGeneration));
      expect(low.code, 'stale_sequence');
      expect((await high).phase, CompanionCommandPhase.applied);
      expect(effects, ['high:play']);
      expect(engine.getPeerSequenceHighWater('phone'), 3);
    });

    test('rejects stale host epoch and expires a command while it waits', () async {
      await _acquire(engine, 'phone');
      final gate = Completer<void>();
      engine.close();
      engine = CompanionCommandEngine(
        hostEpoch: 'boot-1',
        nowMs: () => now,
        handler: (peer, command, context) async {
          if (command.id == 'block') await gate.future;
          context.ensureCurrent();
          effects.add(command.id);
          return CompanionReceipt(peerId: peer, commandId: command.id, phase: CompanionCommandPhase.applied);
        },
      );
      await _acquire(engine, 'phone');
      final blocker = engine.execute('phone', _command('block', 2, generation: engine.controlGeneration));
      final expires = engine.execute('phone', _command('expires', 3, generation: engine.controlGeneration, deadline: 1500));
      final oldEpoch = await engine.execute('phone', _command('old', 4, generation: engine.controlGeneration, epoch: 'boot-0'));
      now += 600;
      gate.complete();
      await blocker;
      expect((await expires).phase, CompanionCommandPhase.expired);
      expect(oldEpoch.code, 'stale_host_epoch');
      expect(effects, ['block']);
    });

    test('expires lease and permits only a new explicit approved grant', () async {
      await _acquire(engine, 'one');
      final takeover = await engine.execute(
        'two',
        _command('takeover-request', 0, type: CompanionCommandType.acquireControl, generation: engine.controlGeneration),
      );
      expect(takeover.code, 'control_owned');
      now += 2001;
      expect(engine.controlOwnerId, isNull);
      final denied = await engine.execute('two', _command('no', 1));
      expect(denied.code, 'control_required');
      engine.grantControl('two');
      final allowed = await engine.execute('two', _command('yes', 1, generation: engine.controlGeneration));
      expect(allowed.phase, CompanionCommandPhase.applied);
    });

    test('local interaction invalidates the active handler context', () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      await engine.close();
      engine = CompanionCommandEngine(
        hostEpoch: 'boot-1',
        nowMs: () => now,
        handler: (peer, command, context) async {
          entered.complete();
          await gate.future;
          context.ensureCurrent();
          effects.add('unsafe');
          return CompanionReceipt(peerId: peer, commandId: command.id, phase: CompanionCommandPhase.applied);
        },
      );
      await _acquire(engine, 'phone');
      final running = engine.execute('phone', _command('inflight', 2, generation: engine.controlGeneration));
      await entered.future;
      engine.localInteraction();
      expect((await running).phase, CompanionCommandPhase.cancelled);
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(effects, isEmpty);
      expect(engine.controlOwnerId, isNull);
    });

    test('three-second local priority blocks acquire without advancing sequence and TV grant bypasses it', () async {
      await engine.close();
      engine = CompanionCommandEngine(
        hostEpoch: 'boot-1',
        nowMs: () => now,
        localPriorityDuration: const Duration(seconds: 3),
        handler: (peer, command, context) async {
          context.ensureCurrent();
          effects.add(command.id);
          return CompanionReceipt(peerId: peer, commandId: command.id, phase: CompanionCommandPhase.applied);
        },
      );
      await _acquire(engine, 'phone');
      expect(engine.getPeerSequenceHighWater('phone'), 0);

      engine.localInteraction();
      final blocked = await engine.execute(
        'phone',
        _command('blocked-acquire', 1, type: CompanionCommandType.acquireControl, generation: engine.controlGeneration),
      );
      expect(blocked.code, 'local_control_active');
      expect(engine.getPeerSequenceHighWater('phone'), 0);

      // A TV UI approval clears the local-priority window immediately.
      engine.grantControl('phone');
      expect(engine.controlOwnerId, 'phone');
      final applied = await engine.execute('phone', _command('after-tv-grant', 1, generation: engine.controlGeneration));
      expect(applied.phase, CompanionCommandPhase.applied);
      expect(engine.getPeerSequenceHighWater('phone'), 1);
      expect(effects, ['after-tv-grant']);
    });

    test('disconnect resolves the queued future as cancelled', () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      await engine.close();
      engine = CompanionCommandEngine(
        hostEpoch: 'boot-1',
        nowMs: () => now,
        handler: (peer, command, context) async {
          entered.complete();
          await gate.future;
          context.ensureCurrent();
          return CompanionReceipt(peerId: peer, commandId: command.id, phase: CompanionCommandPhase.applied);
        },
      );
      await _acquire(engine, 'phone');
      final command = _command('inflight', 2, generation: engine.controlGeneration);
      final running = engine.execute('phone', command);
      await entered.future;
      engine.disconnect('phone');
      expect((await running).phase, CompanionCommandPhase.cancelled);
      expect(engine.getPeerSequenceHighWater('phone'), 2);
      expect((await engine.execute('phone', command)).phase, CompanionCommandPhase.cancelled);
      final replay = await engine.execute('phone', _command('new-id', 2));
      expect(replay.code, 'stale_sequence');
      gate.complete();
    });

    test('handoff can run beyond the five second admission deadline', () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      await engine.close();
      engine = CompanionCommandEngine(
        hostEpoch: 'boot-1',
        nowMs: () => now,
        handler: (peer, command, context) async {
          entered.complete();
          await gate.future;
          context.ensureCurrent();
          return CompanionReceipt(peerId: peer, commandId: command.id, phase: CompanionCommandPhase.applied);
        },
      );
      await _acquire(engine, 'phone');
      final running = engine.execute(
        'phone',
        _command('handoff-long', 1, type: CompanionCommandType.handoff, generation: engine.controlGeneration),
      );
      await entered.future;
      now += 6000;
      expect(engine.renewControl('phone'), isTrue);
      gate.complete();
      expect((await running).phase, CompanionCommandPhase.applied);
    });

    test('long command expires after its thirty second execution budget', () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      await engine.close();
      engine = CompanionCommandEngine(
        hostEpoch: 'boot-1',
        nowMs: () => now,
        handler: (peer, command, context) async {
          entered.complete();
          await gate.future;
          context.ensureCurrent();
          return CompanionReceipt(peerId: peer, commandId: command.id, phase: CompanionCommandPhase.applied);
        },
      );
      await _acquire(engine, 'phone');
      final running = engine.execute(
        'phone',
        _command('handoff-timeout', 1, type: CompanionCommandType.handoff, generation: engine.controlGeneration),
      );
      await entered.future;
      now += 10000;
      expect(engine.renewControl('phone'), isTrue);
      now += 10000;
      expect(engine.renewControl('phone'), isTrue);
      now += 11001;
      gate.complete();
      final result = await running;
      expect(result.phase, CompanionCommandPhase.expired);
      expect(result.code, 'execution_timeout');
    });

    test('handler budget invalidates context and queue stays capped while it drains', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      CompanionExecutionContext? stalledContext;
      await engine.close();
      engine = CompanionCommandEngine(
        hostEpoch: 'boot-1',
        nowMs: () => now,
        leaseDuration: const Duration(seconds: 2),
        maxPendingCommands: 1,
        executionBudget: (_) => const Duration(milliseconds: 30),
        handler: (peer, command, context) async {
          if (command.id == 'stuck') {
            stalledContext = context;
            entered.complete();
            await release.future;
            context.ensureCurrent();
          }
          effects.add(command.id);
          return CompanionReceipt(peerId: peer, commandId: command.id, phase: CompanionCommandPhase.applied);
        },
      );
      await _acquire(engine, 'phone');
      final generation = engine.controlGeneration;
      final stuck = engine.execute('phone', _command('stuck', 1, generation: generation));
      await entered.future;
      final queued = engine.execute('phone', _command('queued', 2, generation: generation));
      final overflow = await engine.execute('phone', _command('overflow', 3, generation: generation));

      expect(overflow.code, 'receiver_busy');
      expect(engine.getPeerSequenceHighWater('phone'), 2);
      expect(engine.receiptFor('phone', 'overflow'), isNull);
      expect(await stuck, isA<CompanionReceipt>().having((receipt) => receipt.phase, 'phase', CompanionCommandPhase.expired));
      expect(stalledContext!.isCurrent, isFalse);
      expect((await queued).phase, CompanionCommandPhase.applied);
      release.complete();
      expect(effects, ['queued']);
    });

    test('committing a playback change keeps the handler current and cancels old queued commands', () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      await engine.close();
      engine = CompanionCommandEngine(
        hostEpoch: 'boot-1',
        nowMs: () => now,
        handler: (peer, command, context) async {
          if (command.type == CompanionCommandType.handoff) {
            entered.complete();
            await gate.future;
            context.ensureCurrent();
            context.commitPlaybackChange();
            context.ensureCurrent();
          }
          return CompanionReceipt(peerId: peer, commandId: command.id, phase: CompanionCommandPhase.applied);
        },
      );
      await _acquire(engine, 'phone');
      final generation = engine.controlGeneration;
      final handoff = engine.execute('phone', _command('handoff', 1, type: CompanionCommandType.handoff, generation: generation));
      await entered.future;
      final oldSeek = engine.execute('phone', _command('old-seek', 2, type: CompanionCommandType.seek, generation: generation));
      gate.complete();
      expect((await handoff).phase, CompanionCommandPhase.applied);
      expect((await oldSeek).phase, CompanionCommandPhase.cancelled);
      expect(engine.playbackGeneration, 1);
    });

    test('latest pending seek supersedes earlier pending seek', () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      await engine.close();
      engine = CompanionCommandEngine(
        hostEpoch: 'boot-1',
        nowMs: () => now,
        handler: (peer, command, context) async {
          if (command.id == 'block') {
            entered.complete();
            await gate.future;
          }
          context.ensureCurrent();
          effects.add(command.id);
          return CompanionReceipt(peerId: peer, commandId: command.id, phase: CompanionCommandPhase.applied);
        },
      );
      await _acquire(engine, 'phone');
      final generation = engine.controlGeneration;
      final block = engine.execute('phone', _command('block', 2, generation: generation));
      await entered.future;
      final oldSeek = engine.execute('phone', _command('seek-1', 3, type: CompanionCommandType.seek, generation: generation));
      final newSeek = engine.execute('phone', _command('seek-2', 4, type: CompanionCommandType.seek, generation: generation));
      expect((await oldSeek).phase, CompanionCommandPhase.superseded);
      gate.complete();
      await block;
      expect((await newSeek).phase, CompanionCommandPhase.applied);
      expect(effects, ['block', 'seek-2']);
    });
  });
}

Future<void> _acquire(CompanionCommandEngine engine, String peerId) async {
  final receipt = await engine.execute(peerId, _command('acquire-$peerId', 0, type: CompanionCommandType.acquireControl));
  expect(receipt.phase, CompanionCommandPhase.applied);
}

CompanionCommand _command(
  String id,
  int seq, {
  CompanionCommandType type = CompanionCommandType.play,
  int generation = 0,
  int playbackGeneration = 0,
  int deadline = 5000,
  String epoch = 'boot-1',
  Map<String, Object?> args = const {},
}) => CompanionCommand(
  id: id,
  hostEpoch: epoch,
  clientSeq: seq,
  controlGeneration: generation,
  playbackGeneration: playbackGeneration,
  deadlineMs: deadline,
  type: type,
  arguments: args,
);
