import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/tv_companion/application/companion_command_engine.dart';
import 'package:mg_read/features/tv_companion/domain/companion_command.dart';

void main() {
  test('LAN controller acquisition automatically takes over and fences the former owner', () async {
    final engine = CompanionCommandEngine(
      hostEpoch: 'tv-boot',
      allowAutomaticTakeover: true,
      nowMs: () => 1000,
      handler: (peer, command, context) async =>
          CompanionReceipt(peerId: peer, commandId: command.id, phase: CompanionCommandPhase.applied),
    );
    try {
      final first = await engine.execute('phone-one', _acquire('first', engine.controlGeneration));
      expect(first.phase, CompanionCommandPhase.applied);
      expect(engine.controlOwnerId, 'phone-one');
      final generationBeforeTakeover = engine.controlGeneration;

      final second = await engine.execute('phone-two', _acquire('second', generationBeforeTakeover));

      expect(second.phase, CompanionCommandPhase.applied);
      expect(engine.controlOwnerId, 'phone-two');
      expect(engine.controlGeneration, generationBeforeTakeover + 1);
      final stale = await engine.execute(
        'phone-one',
        CompanionCommand(
          id: 'former-owner',
          hostEpoch: 'tv-boot',
          clientSeq: 2,
          controlGeneration: generationBeforeTakeover,
          playbackGeneration: 0,
          deadlineMs: 5000,
          type: CompanionCommandType.play,
        ),
      );
      expect(stale.code, 'control_required');
    } finally {
      await engine.close();
    }
  });
}

CompanionCommand _acquire(String id, int generation) => CompanionCommand(
  id: id,
  hostEpoch: 'tv-boot',
  clientSeq: 1,
  controlGeneration: generation,
  playbackGeneration: 0,
  deadlineMs: 5000,
  type: CompanionCommandType.acquireControl,
);
