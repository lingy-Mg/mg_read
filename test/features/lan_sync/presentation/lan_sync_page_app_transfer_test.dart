/// 通过生产扫码路由、控制器和本机 HTTP 复现确认后的接收流程；系统权限及安装入口使用夹具。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/application/app_transfer_controller.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';
import 'package:mg_read/features/lan_sync/data/app_transfer_transport.dart';
import 'package:mg_read/features/lan_sync/domain/app_transfer_qr_payload.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';
import 'package:mg_read/features/lan_sync/presentation/lan_sync_page.dart';

import '../application/app_transfer_testkit.dart';
import '../application/lan_sync_awake_testkit.dart' show installAwakeProbe, waitUntil;

void main() {
  installAwakeProbe();
  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['event', 'deviceOrientation']) {
      messenger.setMockMethodCallHandler(MethodChannel('dev.steenbakker.mobile_scanner/scanner/$name'), (_) async => null);
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.steenbakker.mobile_scanner/scanner/method'),
      (call) async => switch (call.method) {
        'state' => 1,
        'start' => {
          'textureId': 1,
          'cameraDirection': 1,
          'size': {'width': 400.0, 'height': 400.0},
        },
        _ => null,
      },
    );
  });

  testWidgets('scanned App confirmation keeps permission retry, download and installer result visible', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final senderService = TransferTestService()..packageGate = Completer<void>();
    final receiverService = TransferTestService(build: 1)
      ..permissionRequired = true
      ..installerGate = Completer<void>();
    final sender = (await tester.runAsync(() => AppTransferSenderService.start(senderService)))!;
    addTearDown(senderService.close);
    addTearDown(sender.close);
    final container = transferContainer(receiverService);
    await _pumpPage(tester, container);
    await _scan(tester, sender.connectionOffer);
    await tester.runAsync(() => waitUntil(() => container.read(appTransferControllerProvider).phase == AppTransferPhase.ready));
    await tester.pump();
    expect(find.text('接收 App'), findsOneWidget);
    expect(find.text('1.0.1 (1)'), findsOneWidget);
    expect(find.text('1.0.2 (2)'), findsOneWidget);
    expect(find.text(container.read(appTransferControllerProvider).pairingCode!), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('app-transfer-upgrade')));
    await tester.runAsync(() => tester.tap(find.byKey(const Key('app-transfer-upgrade'))));
    await tester.pump();
    expect(find.textContaining('请在系统设置中允许安装未知来源应用'), findsOneWidget);
    expect(find.byKey(const Key('app-transfer-upgrade')), findsOneWidget);
    expect(senderService.prepareCalls, 0);

    receiverService.permissionRequired = false;
    await tester.ensureVisible(find.byKey(const Key('app-transfer-upgrade')));
    await tester.runAsync(() => tester.tap(find.byKey(const Key('app-transfer-upgrade'))));
    await tester.pump();
    await tester.runAsync(() => waitUntil(() => senderService.prepareCalls == 1));
    await tester.pump();
    expect(find.text('正在等待发送端准备 App 安装包'), findsOneWidget);
    expect(find.byKey(const Key('app-transfer-progress')), findsOneWidget);

    await tester.runAsync(() async {
      senderService.packageGate!.complete();
      await waitUntil(() => receiverService.installerCalls == 1);
    });
    await tester.pump();
    expect(find.text('校验完成，正在打开系统安装程序'), findsOneWidget);
    await tester.runAsync(() async {
      receiverService.installerGate!.complete();
      await waitUntil(() => container.read(appTransferControllerProvider).phase == AppTransferPhase.completed);
    });
    await tester.pump();
    expect(receiverService.installedBytes, senderService.bytes);
    expect(find.text('已打开系统安装程序，请按提示完成升级'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('app-transfer-finish')));
    await tester.tap(find.byKey(const Key('app-transfer-finish')));
    await tester.pumpAndSettle();
    expect(container.read(appTransferControllerProvider).phase, AppTransferPhase.idle);
    await _disposePage(tester, container);
  });

  testWidgets('scanned platform mismatch remains visible and closing allows a new attempt', (tester) async {
    final senderService = TransferTestService(platform: AppUpdatePlatform.windows);
    final sender = (await tester.runAsync(() => AppTransferSenderService.start(senderService)))!;
    addTearDown(senderService.close);
    addTearDown(sender.close);
    final container = transferContainer(TransferTestService(build: 1));
    await _pumpPage(tester, container);
    await _scan(tester, sender.connectionOffer);
    await tester.runAsync(() => waitUntil(() => container.read(appTransferControllerProvider).phase == AppTransferPhase.failed));
    await tester.pump();
    expect(find.text('对方没有适用于当前设备平台的 App 安装包'), findsOneWidget);
    expect(find.text('错误码：app_update_platform_mismatch'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('app-transfer-finish')));
    await tester.tap(find.byKey(const Key('app-transfer-finish')));
    await tester.pumpAndSettle();
    expect(container.read(appTransferControllerProvider).phase, AppTransferPhase.idle);
    await _disposePage(tester, container);
  });

  testWidgets('installer failure after same-version forced confirmation is visible', (tester) async {
    final senderService = TransferTestService();
    final sender = (await tester.runAsync(() => AppTransferSenderService.start(senderService)))!;
    addTearDown(senderService.close);
    addTearDown(sender.close);
    final receiverService = TransferTestService()..failInstaller = true;
    final container = transferContainer(receiverService);
    await _pumpPage(tester, container);
    await _scan(tester, sender.connectionOffer);
    await tester.runAsync(() => waitUntil(() => container.read(appTransferControllerProvider).phase == AppTransferPhase.ready));
    await tester.pump();
    expect(receiverService.installerCalls, 0);
    await tester.ensureVisible(find.byKey(const Key('app-transfer-force')));
    await tester.runAsync(() => tester.tap(find.byKey(const Key('app-transfer-force'))));
    await tester.pump();
    await tester.runAsync(() => waitUntil(() => container.read(appTransferControllerProvider).phase == AppTransferPhase.failed));
    await tester.pump();
    expect(find.text('系统安装程序启动失败'), findsOneWidget);
    expect(find.text('错误码：app_update_installer_failed'), findsOneWidget);
    await _disposePage(tester, container);
  });
}

Future<void> _pumpPage(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: LanSyncPage(onBackRequested: () {}, onDestinationRequested: (_) {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _scan(WidgetTester tester, AppTransferConnectionOffer offer) async {
  await tester.runAsync(() => tester.tap(find.byKey(const Key('lan-sync-scan'))));
  await tester.pumpAndSettle();
  final scanner = tester.widget<MobileScanner>(find.byKey(const Key('lan-sync-qr-scanner')));
  await tester.runAsync(() async {
    scanner.onDetect!(BarcodeCapture(barcodes: [Barcode(rawValue: AppTransferQrPayload.encode(offer))]));
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _disposePage(WidgetTester tester, ProviderContainer container) async {
  await container.read(deviceSyncControllerProvider.notifier).stop();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}
