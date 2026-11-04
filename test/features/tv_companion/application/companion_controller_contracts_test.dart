import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/tv_companion/application/companion_controller.dart';
import 'package:mg_read/features/tv_companion/data/companion_repository.dart';
import 'package:mg_read/features/tv_companion/data/companion_network.dart';
import 'package:mg_read/features/tv_companion/domain/companion_command.dart';
import 'package:mg_read/features/tv_companion/domain/companion_models.dart';

import 'companion_controller_testkit.dart';

void main() {
  late CompanionPairFixture fixture;
  final tempDirs = <Directory>[];

  tearDown(() async {
    await fixture.close();
    for (final directory in tempDirs) {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
    tempDirs.clear();
  });

  test('a touch interaction token is rejected after local TV input without reacquiring control', () async {
    fixture = await CompanionPairFixture.create();
    await fixture.connect();
    await fixture.waitFor(() => fixture.phone.remoteState != null);
    final token = await fixture.phone.beginInteraction();
    expect(fixture.phone.hasControl, isTrue);

    fixture.tv.localInteraction();
    await fixture.waitFor(
      () => fixture.phone.remoteState?.controllerId == null && fixture.phone.remoteState!.controlGeneration > token.controlGeneration,
    );

    await expectLater(
      fixture.phone.interactionCommand(token, CompanionCommandType.navigate, arguments: const {'key': 'right'}),
      throwsA(isA<CompanionFailure>().having((error) => error.code, 'code', 'interaction_changed')),
    );
    expect(fixture.phone.hasControl, isFalse);
    expect(fixture.tv.controlOwnerId, isNull);
  });

  test('interaction command admission is fenced by the captured host epoch and target', () async {
    fixture = await CompanionPairFixture.create();
    await fixture.connect();
    await fixture.waitFor(() => fixture.phone.remoteState != null);
    final epochToken = await fixture.phone.beginInteraction();
    final state = fixture.phone.remoteState!;
    fixture.phone.remoteState = CompanionPlaybackSnapshot(
      sequence: state.sequence + 1,
      hostEpoch: 'restarted-tv-epoch',
      serverMs: state.serverMs,
      controlGeneration: state.controlGeneration,
      playbackGeneration: state.playbackGeneration,
      controllerId: state.controllerId,
      status: state.status,
    );
    await expectLater(
      fixture.phone.interactionCommand(epochToken, CompanionCommandType.navigate, arguments: const {'key': 'left'}),
      throwsA(isA<CompanionFailure>().having((error) => error.code, 'code', 'interaction_changed')),
    );

    fixture.phone.remoteState = state;
    final targetToken = await fixture.phone.beginInteraction();
    await fixture.phone.disconnect();
    await expectLater(
      fixture.phone.interactionCommand(targetToken, CompanionCommandType.navigate, arguments: const {'key': 'left'}),
      throwsA(isA<CompanionFailure>().having((error) => error.code, 'code', 'interaction_changed')),
    );
    await fixture.waitFor(() => fixture.tv.controlOwnerId == null);
    expect(fixture.tv.controlOwnerId, isNull);
  });

  test('a delayed permission preflight cannot replace the last endpoint for the same paired device', () async {
    final gatedNetwork = _FirstPermissionGateNetwork();
    final oldNavigations = <String>[];
    final newNavigations = <String>[];
    fixture = await CompanionPairFixture.create(
      phoneNetwork: gatedNetwork,
      onNavigate: (key) async {
        oldNavigations.add(key);
      },
    );
    final alternate = await CompanionAlternateTvHost.create(
      fixture: fixture,
      onNavigate: (key) async {
        newNavigations.add(key);
      },
    );
    final previousEndpoint = CompanionEndpoint(
      deviceId: companionTestTvId,
      label: 'Previous endpoint',
      address: '127.0.0.1',
      port: fixture.tvServer.port,
      expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      receiving: true,
    );
    final staleConnect = fixture.phone.connect(previousEndpoint);
    try {
      await gatedNetwork.firstPermissionEntered.future.timeout(const Duration(seconds: 3));
      await fixture.phone.connect(alternate.endpoint);
      await fixture.waitFor(() => fixture.phone.remoteState?.hostEpoch == alternate.tv.hostEpoch);
      expect(fixture.phone.selectedEndpoint?.label, 'Replacement endpoint');

      gatedNetwork.releaseFirstPermission.complete();
      await staleConnect;
      await fixture.waitFor(() => fixture.phone.remoteState?.hostEpoch == alternate.tv.hostEpoch);
      expect(fixture.phone.connectionStatus, CompanionConnectionStatus.connected);

      final receipt = await fixture.phone.command(CompanionCommandType.navigate, arguments: const {'key': 'confirm'});
      expect(receipt.phase, CompanionCommandPhase.applied);
      expect(newNavigations, ['confirm']);
      expect(oldNavigations, isEmpty);
    } finally {
      if (!gatedNetwork.releaseFirstPermission.isCompleted) gatedNetwork.releaseFirstPermission.complete();
      try {
        await staleConnect;
      } on Object {
        // Preserve the assertion failure while ensuring its pending socket closes.
      }
      await fixture.phone.disconnect();
      await alternate.close();
    }
  });

  test('disconnect cancels an in-flight handoff and reconnect does not resend the mutation', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var launches = 0;
    fixture = await CompanionPairFixture.create(
      onHandoff: (content, context) async {
        launches++;
        entered.complete();
        await release.future;
        context.ensureCurrent();
      },
    );
    await fixture.connect();
    await fixture.waitFor(() => fixture.phone.remoteState != null);
    final token = await fixture.phone.beginInteraction();
    final content = const CompanionContentRef(
      pluginId: 'video-source',
      contentId: 'item-1',
      title: 'Title',
      groupId: 'group-1',
      episodeId: 'episode-1',
    );
    final handoff = fixture.phone.interactionCommand(token, CompanionCommandType.handoff, arguments: content.toJson());
    final failedHandoff = expectLater(handoff, throwsA(anything));
    await entered.future.timeout(const Duration(seconds: 3));

    await fixture.phone.disconnect(rememberSelection: true);
    await fixture.waitFor(() => fixture.tv.connectedControllerIds.isEmpty);
    release.complete();
    await failedHandoff;
    await fixture.connect();
    await fixture.waitFor(() => fixture.phone.remoteState != null);

    expect(launches, 1);
    expect(fixture.phone.hasControl, isFalse);
  });

  test('favorites and history require browse permission, then return only after explicit grant', () async {
    final directory = await Directory.systemTemp.createTemp('companion-library-permission-');
    tempDirs.add(directory);
    final library = await ContentLibrary.open(dataRoot: directory);
    fixture = await CompanionPairFixture.create(tvLibrary: library);
    await fixture.connect();
    await fixture.waitFor(() => fixture.phone.remoteState != null);

    for (final method in ['favorites', 'history']) {
      await expectLater(
        fixture.phone.request(method),
        throwsA(isA<CompanionFailure>().having((error) => error.code, 'code', 'library_permission_required')),
      );
    }

    await fixture.tv.setPolicy(companionTestPhoneId, const CompanionPolicy(control: true, browseLibrary: true));
    expect((await fixture.phone.request('favorites'))['items'], isEmpty);
    expect((await fixture.phone.request('history'))['entries'], isEmpty);
  });

  test('automatic progress push includes this controller association and excludes another phone', () async {
    final tvDirectory = await Directory.systemTemp.createTemp('companion-history-tv-');
    final phoneDirectory = await Directory.systemTemp.createTemp('companion-history-phone-');
    tempDirs.addAll([tvDirectory, phoneDirectory]);
    final tvLibrary = await ContentLibrary.open(dataRoot: tvDirectory);
    final phoneLibrary = await ContentLibrary.open(dataRoot: phoneDirectory);
    await tvLibrary.saveVideoHistory(_checkpoint(contentId: 'associated', controllerDeviceId: companionTestPhoneId));
    await tvLibrary.saveVideoHistory(_checkpoint(contentId: 'other-controller', controllerDeviceId: 'phone-device-0002'));
    fixture = await CompanionPairFixture.create(tvLibrary: tvLibrary, phoneLibrary: phoneLibrary);
    await fixture.connect();
    final received = await _waitForHistory(phoneLibrary);

    expect(received.map((entry) => entry.checkpoint.contentId).toSet(), {'associated'});
    expect(received.every((entry) => entry.checkpoint.controllerDeviceId == companionTestPhoneId), isTrue);
  });
}

Future<List<VideoHistoryEntry>> _waitForHistory(ContentLibrary library) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(seconds: 4)) {
    final entries = await library.listVideoHistory(includeRemoteBranches: true, limit: 20);
    if (entries.isNotEmpty) return entries;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException('history did not arrive');
}

VideoHistoryCheckpoint _checkpoint({required String contentId, required String controllerDeviceId}) => VideoHistoryCheckpoint(
  pluginId: 'video-source',
  contentId: contentId,
  pluginVersion: '1',
  title: contentId,
  groupId: 'group-1',
  episodeId: 'episode-1',
  position: const Duration(seconds: 15),
  duration: const Duration(minutes: 10),
  originDeviceId: companionTestTvId,
  playbackSessionId: 'session-$contentId',
  sequence: 1,
  localGeneration: 1,
  updatedAtUtc: DateTime.utc(2026, 11, 4),
  controllerDeviceId: controllerDeviceId,
);

final class _FirstPermissionGateNetwork extends CompanionNetwork {
  final firstPermissionEntered = Completer<void>();
  final releaseFirstPermission = Completer<void>();
  var _permissionCalls = 0;

  @override
  Future<bool> available() async => true;

  @override
  Future<bool> ensurePermission() async {
    if (_permissionCalls++ == 0) {
      firstPermissionEntered.complete();
      await releaseFirstPermission.future;
    }
    return true;
  }

  @override
  Future<List<String>> addresses() async => ['127.0.0.1'];
}
