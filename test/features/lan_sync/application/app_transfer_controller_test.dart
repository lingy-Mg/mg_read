/// 覆盖确认后的权限返回、实际 HTTP 下载、取消与异步迟到结果；不代表真机安装验收。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/lan_sync/application/app_transfer_controller.dart';
import 'package:mg_read/features/lan_sync/data/app_transfer_transport.dart';
import 'package:mg_read/features/lan_sync/domain/app_transfer_qr_payload.dart';

import 'app_transfer_testkit.dart';
import 'lan_sync_awake_testkit.dart' show installAwakeProbe, waitUntil;

void main() {
  installAwakeProbe();

  test('permission return can retry and transfers actual verified bytes through every visible stage', () async {
    final senderService = TransferTestService();
    final receiverService = TransferTestService(build: 1)..permissionRequired = true;
    final sender = await AppTransferSenderService.start(senderService);
    addTearDown(senderService.close);
    addTearDown(sender.close);
    final container = transferContainer(receiverService);
    final controller = container.read(appTransferControllerProvider.notifier);
    final phases = <AppTransferPhase>[];
    final subscription = container.listen(appTransferControllerProvider, (_, next) => phases.add(next.phase));
    addTearDown(subscription.close);
    await controller.connectOffer(sender.connectionOffer);
    await controller.install(force: false);
    expect(container.read(appTransferControllerProvider).phase, AppTransferPhase.ready);
    expect(container.read(appTransferControllerProvider).errorCode, 'app_update_install_permission_required');
    expect(senderService.prepareCalls, 0);

    receiverService.permissionRequired = false;
    await controller.install(force: false);
    expect(receiverService.installedBytes, senderService.bytes);
    expect(receiverService.installerCalls, 1);
    expect(
      phases,
      containsAllInOrder([
        AppTransferPhase.requestingPermission,
        AppTransferPhase.ready,
        AppTransferPhase.requestingPermission,
        AppTransferPhase.preparingPackage,
        AppTransferPhase.downloading,
        AppTransferPhase.verifying,
        AppTransferPhase.launchingInstaller,
        AppTransferPhase.completed,
      ]),
    );
  });

  test('double confirmation and cancellation during permission cannot start a late install', () async {
    final senderService = TransferTestService();
    final receiverService = TransferTestService(build: 1)..permissionGate = Completer<void>();
    final sender = await AppTransferSenderService.start(senderService);
    addTearDown(senderService.close);
    addTearDown(sender.close);
    final container = transferContainer(receiverService);
    final controller = container.read(appTransferControllerProvider.notifier);
    await controller.connectOffer(sender.connectionOffer);
    final installing = controller.install(force: false);
    await waitUntil(() => receiverService.permissionCalls == 1);
    await controller.install(force: false);
    expect(receiverService.permissionCalls, 1);
    await controller.cancel();
    receiverService.permissionGate!.complete();
    await installing;
    expect(container.read(appTransferControllerProvider).phase, AppTransferPhase.idle);
    expect(senderService.prepareCalls, 0);
    expect(receiverService.installerCalls, 0);
  });

  test('cancel during version lookup does not revive the scanned session', () async {
    final service = TransferTestService()..versionGate = Completer<void>();
    final container = transferContainer(service);
    final controller = container.read(appTransferControllerProvider.notifier);
    final connecting = controller.connectOffer(
      AppTransferConnectionOffer(sessionId: 'cancelled_session', port: 1234, addresses: ['192.168.1.1']),
    );
    await waitUntil(() => container.read(appTransferControllerProvider).phase == AppTransferPhase.preparing);
    await controller.cancel();
    service.versionGate!.complete();
    await connecting;
    expect(container.read(appTransferControllerProvider).phase, AppTransferPhase.idle);
  });

  test('silent sender package preparation fails with bounded timeout and no installer', () async {
    final senderService = TransferTestService()..packageGate = Completer<void>();
    final receiverService = TransferTestService(build: 1);
    final sender = await AppTransferSenderService.start(senderService);
    addTearDown(senderService.close);
    addTearDown(receiverService.close);
    addTearDown(sender.close);
    final receiver = await AppTransferReceiverConnection.connectAny(
      sender.connectionOffer,
      receiverService.version,
      controlTimeout: const Duration(milliseconds: 100),
    );
    addTearDown(receiver.close);
    await expectLater(
      receiver.downloadAndInstall(receiverService, receiverService.version, force: false),
      throwsA(predicate((error) => error.toString().contains('app_update_request_timeout'))),
    );
    expect(receiverService.installerCalls, 0);
    senderService.packageGate!.complete();
    await waitUntil(() => senderService.root != null);
  });

  test('cancel after final download byte prevents the system installer from opening', () async {
    final senderService = TransferTestService();
    final receiverService = TransferTestService(build: 1);
    final sender = await AppTransferSenderService.start(senderService);
    addTearDown(senderService.close);
    addTearDown(receiverService.close);
    addTearDown(sender.close);
    final receiver = await AppTransferReceiverConnection.connectAny(sender.connectionOffer, receiverService.version);
    addTearDown(receiver.close);
    await expectLater(
      receiver.downloadAndInstall(
        receiverService,
        receiverService.version,
        force: false,
        onStage: (stage) {
          if (stage == AppTransferReceiveStage.verifying) receiver.close();
        },
      ),
      throwsA(predicate((error) => error.toString().contains('app_update_cancelled'))),
    );
    expect(receiverService.installerCalls, 0);
  });
}
