/// Opt-in Windows LAN probe for the isolated physical-TV acceptance app.
/// Uses real UDP discovery and the production encrypted transport/wire types;
/// it never targets the normal application or creates paired sync trust.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mg_read/features/tv_companion/data/companion_secure_channel.dart';
import 'package:mg_read/features/tv_companion/domain/companion_command.dart';

Future<void> main() async {
  final endpoint = await _discover();
  final channel = await CompanionSecureChannel.connect(
    uri: Uri(scheme: 'ws', host: endpoint.address, port: endpoint.port, path: '/companion/v1/ws'),
    localDeviceId: 'companion-windows-probe',
    remoteDeviceId: endpoint.id,
    sharedSecret: const [],
  );
  Map<String, Object?>? state;
  var sequence = 0;
  final pending = <String, Completer<CompanionReceipt>>{};
  final subscription = channel.messages.listen((message) {
    if (message['kind'] == 'state') state = Map<String, Object?>.from(message['state'] as Map);
    if (message['kind'] == 'welcome') sequence = (message['sequenceHighWater'] as int) + 1;
    if (message['kind'] == 'receipt') {
      final receipt = CompanionReceipt.fromJson(message['receipt']);
      if (receipt.isTerminal) pending.remove(receipt.commandId)?.complete(receipt);
    }
  });
  final heartbeat = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(channel.send({'kind': 'ping', 'control': true})));
  Future<void> refresh() async {
    final previous = state?['sequence'];
    await channel.send({'kind': 'stateRequest'});
    await _wait(() => state != null && state!['sequence'] != previous);
  }

  Future<CompanionReceipt> command(
    CompanionCommandType type, {
    Map<String, Object?> arguments = const {},
    bool expectFailure = false,
  }) async {
    await refresh();
    final current = state!;
    final id = 'probe-${sequence++}';
    final result = Completer<CompanionReceipt>();
    pending[id] = result;
    await channel.send({
      'kind': 'command',
      'command': CompanionCommand(
        id: id,
        hostEpoch: current['hostEpoch'] as String,
        clientSeq: sequence,
        controlGeneration: current['controlGeneration'] as int,
        playbackGeneration: current['playbackGeneration'] as int,
        deadlineMs: (current['serverMs'] as int) + 4000,
        type: type,
        arguments: arguments,
      ).toJson(),
    });
    final receipt = await result.future.timeout(const Duration(seconds: 35));
    final accepted = expectFailure
        ? receipt.phase == CompanionCommandPhase.failed
        : receipt.phase == CompanionCommandPhase.applied || receipt.phase == CompanionCommandPhase.started;
    if (!accepted) {
      throw StateError('${type.name}: ${receipt.phase.name} ${receipt.code}');
    }
    stdout.writeln('${type.name}: ${receipt.phase.name}');
    await refresh();
    return receipt;
  }

  final report = <String, Object?>{
    'discovered': {'id': endpoint.id, 'address': endpoint.address, 'port': endpoint.port},
  };
  try {
    await _wait(() => state != null);
    await command(CompanionCommandType.acquireControl);
    await command(
      CompanionCommandType.handoff,
      arguments: {
        'kind': 'source',
        'pluginId': 'companion-qa',
        'pluginVersion': 'qa-1',
        'contentId': 'sintel-native-acceptance',
        'title': 'Sintel physical TV acceptance',
        'groupId': 'qa',
        'episodeId': 'sample',
        'positionMs': 0,
        'useTvProgress': false,
      },
    );
    await _wait(() => state?['firstFrame'] == true && state?['playing'] == true);
    report['nativePlayback'] = state;
    await command(CompanionCommandType.pause);
    await _wait(() => state?['playing'] == false);
    report['paused'] = state;
    await command(CompanionCommandType.seek, arguments: {'positionMs': 12000});
    await _wait(() => ((state?['positionMs'] as int? ?? 0) - 12000).abs() < 1500);
    report['seek'] = state;
    await command(CompanionCommandType.play);
    await _wait(() => state?['playing'] == true && (state?['positionMs'] as int? ?? 0) > 13000);
    report['resumed'] = state;
    await command(CompanionCommandType.nextEpisode);
    await _wait(() => (state?['content'] as Map?)?['episodeId'] == 'next' && state?['playing'] == true);
    report['next'] = state;
    await command(CompanionCommandType.selectEpisode, arguments: {'groupId': 'qa', 'episodeId': 'unavailable'}, expectFailure: true);
    await _wait(() => (state?['content'] as Map?)?['episodeId'] == 'next' && state?['playing'] == true);
    report['failedCandidateRetainedPlayback'] = state;
    await command(CompanionCommandType.exitPlayback);
    report['noPairingSecret'] = true;
    stdout.writeln('COMPANION_LAN_PROBE ${jsonEncode(report)}');
    final output = Platform.environment['MGREAD_COMPANION_PROBE_REPORT'];
    if (output != null) await File(output).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  } finally {
    heartbeat.cancel();
    await subscription.cancel();
    await channel.close();
  }
}

Future<({String address, int port, String id})> _discover() async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 47232, reuseAddress: true);
  final result = Completer<({String address, int port, String id})>();
  final subscription = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    Datagram? packet;
    while ((packet = socket.receive()) != null) {
      try {
        final raw = jsonDecode(utf8.decode(packet!.data)) as Map;
        if (raw['kind'] != 'mgread-paired-sync' || raw['deviceId'] != 'companion-qa-tv-receiver') continue;
        if ((raw['services'] as Map?)?['receiving'] != true || result.isCompleted) continue;
        result.complete((address: packet.address.address, port: raw['port'] as int, id: raw['deviceId'] as String));
      } on Object {
        // Ignore unrelated or malformed discovery packets.
      }
    }
  });
  try {
    return await result.future.timeout(const Duration(seconds: 25));
  } finally {
    await subscription.cancel();
    socket.close();
  }
}

Future<void> _wait(bool Function() reached) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!reached() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  if (!reached()) throw TimeoutException('Physical TV state did not reach the expected value');
}
