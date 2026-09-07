/// 扫码发送/接收实际 HTTP 流程及慢业务阶段的亮屏边界；不代表 Android 设备验收。
library;

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_controller.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_screen_awake.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'lan_sync_awake_testkit.dart';

void main() {
  installAwakeProbe();

  test('manual sender and receiver keep awake through preparation, install, apply and cleanup', () async {
    final senderGateway = AwakeGateway();
    final manifest = senderGateway.pause('manifest');
    final archive = senderGateway.pause('archive');
    final sender = manualContainer(senderGateway);
    final sending = sender.read(lanSyncControllerProvider.notifier).startSending();
    await waitUntil(() => senderGateway.reached.contains('manifest'));
    expect(ScreenAwakeCoordinator.instance.holderCount, 1);
    manifest.complete();
    await sending;
    expect(ScreenAwakeCoordinator.instance.holderCount, 0, reason: 'waiting for a receiver');

    final gateway = AwakeGateway();
    final preview = gateway.pause('preview');
    final install = gateway.pause('install');
    final apply = gateway.pause('apply');
    final cleanup = gateway.pause('cleanup');
    final receiver = manualContainer(gateway);
    final controller = receiver.read(lanSyncControllerProvider.notifier);
    await controller.startReceiving();
    expect(ScreenAwakeCoordinator.instance.holderCount, 0, reason: 'discovery');
    await controller.connectOffer(sender.read(lanSyncControllerProvider).connectionOffer!);
    expect(ScreenAwakeCoordinator.instance.holderCount, 0, reason: 'pairing confirmation');
    final confirming = controller.confirmReceiverPairing();
    await waitUntil(() => gateway.reached.contains('preview'));
    expect(ScreenAwakeCoordinator.instance.holderCount, greaterThan(0));
    preview.complete();
    await confirming;
    await waitUntil(() => ScreenAwakeCoordinator.instance.holderCount == 0);
    expect(receiver.read(lanSyncControllerProvider).phase, LanSyncPhase.previewing);
    final importing = controller.beginImport();
    await waitUntil(() => senderGateway.reached.contains('archive'));
    expect(ScreenAwakeCoordinator.instance.holderCount, 2, reason: 'both ends before the first plugin byte');
    archive.complete();
    await waitUntil(() => gateway.reached.contains('install'));
    expect(ScreenAwakeCoordinator.instance.holderCount, greaterThan(0));
    install.complete();
    await waitUntil(() => gateway.reached.contains('apply'));
    expect(ScreenAwakeCoordinator.instance.holderCount, greaterThan(0));
    apply.complete();
    await waitUntil(() => gateway.reached.contains('cleanup'));
    expect(ScreenAwakeCoordinator.instance.holderCount, greaterThan(0));
    cleanup.complete();
    await importing;
    await waitUntil(() => ScreenAwakeCoordinator.instance.holderCount == 0);
    expect(sender.read(lanSyncControllerProvider).phase, LanSyncPhase.completed);
    expect(receiver.read(lanSyncControllerProvider).phase, LanSyncPhase.completed);
  });

  for (final dispose in [false, true]) {
    test('manual ${dispose ? 'dispose' : 'cancel'} retains awake until pending preparation and cleanup exit', () async {
      final gateway = AwakeGateway();
      final manifest = gateway.pause('manifest');
      final cleanup = gateway.pause('cleanup');
      final container = manualContainer(gateway);
      final controller = container.read(lanSyncControllerProvider.notifier);
      final starting = controller.startSending();
      await waitUntil(() => gateway.reached.contains('manifest'));
      Future<void>? cancelling;
      if (dispose) {
        container.invalidate(lanSyncControllerProvider);
      } else {
        cancelling = controller.cancel();
      }
      expect(ScreenAwakeCoordinator.instance.holderCount, greaterThan(0));
      manifest.complete();
      await waitUntil(() => gateway.reached.contains('cleanup'));
      expect(ScreenAwakeCoordinator.instance.holderCount, greaterThan(0));
      cleanup.complete();
      await starting;
      await cancelling;
      await waitUntil(() => ScreenAwakeCoordinator.instance.holderCount == 0);
      expect(gateway.cancellations, 1);
    });
  }

  test('preparation failure releases after cleanup', () async {
    final gateway = AwakeGateway()..failure = 'manifest';
    final container = manualContainer(gateway);
    await container.read(lanSyncControllerProvider.notifier).startSending();
    await waitUntil(() => gateway.cancellations == 1);
    await waitUntil(() => ScreenAwakeCoordinator.instance.holderCount == 0);
    expect(container.read(lanSyncControllerProvider).phase, LanSyncPhase.failed);
  });

  for (final cancel in [false, true]) {
    test('manual receiver ${cancel ? 'cancel during write' : 'installation failure'} releases after cleanup', () async {
      final sender = manualContainer(AwakeGateway());
      await sender.read(lanSyncControllerProvider.notifier).startSending();
      final gateway = AwakeGateway();
      if (!cancel) gateway.failure = 'install';
      final apply = cancel ? gateway.pause('apply') : null;
      final cleanup = gateway.pause('cleanup');
      final receiver = manualContainer(gateway);
      final controller = receiver.read(lanSyncControllerProvider.notifier);
      await controller.startReceiving();
      await controller.connectOffer(sender.read(lanSyncControllerProvider).connectionOffer!);
      await controller.confirmReceiverPairing();
      final importing = controller.beginImport();
      Future<void>? cancelling;
      if (cancel) {
        await waitUntil(() => gateway.reached.contains('apply'));
        cancelling = controller.cancel();
        expect(ScreenAwakeCoordinator.instance.holderCount, greaterThan(0));
        apply!.complete();
      }
      await waitUntil(() => gateway.reached.contains('cleanup'));
      expect(ScreenAwakeCoordinator.instance.holderCount, greaterThan(0));
      cleanup.complete();
      await importing;
      await cancelling;
      await waitUntil(() => ScreenAwakeCoordinator.instance.holderCount == 0);
      expect(receiver.read(lanSyncControllerProvider).phase, cancel ? LanSyncPhase.cancelled : LanSyncPhase.failed);
    });
  }

  test('slow and failed platform calls do not block cancellation or override sync errors', () async {
    const channel = MethodChannel('novel_reader_ui/system');
    final lateAcquire = Completer<void>();
    final calls = <bool>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      final enabled = (call.arguments as Map)['keepScreenOn'] as bool;
      calls.add(enabled);
      if (enabled && !lateAcquire.isCompleted) await lateAcquire.future;
      return null;
    });
    final awake = LanSyncScreenAwake();
    await waitUntil(() => calls.isNotEmpty);
    await awake.close().timeout(const Duration(seconds: 1));
    await waitUntil(() => calls.contains(false));
    expect(ScreenAwakeCoordinator.instance.holderCount, 0);
    lateAcquire.complete();
    await waitUntil(() => calls.length == 3);
    expect(calls, [true, false, false]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'test_unavailable');
    });
    final error = StateError('sync_failure');
    await expectLater(LanSyncScreenAwake.run<void>(() async => throw error), throwsA(same(error)));
    await Future<void>.delayed(Duration.zero);
    expect(ScreenAwakeCoordinator.instance.holderCount, 0);
  });

  test('ending a reverse wait cannot release an active incoming operation or reader', () async {
    const channel = MethodChannel('novel_reader_ui/system');
    final calls = <Map<Object?, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(Map<Object?, Object?>.from(call.arguments as Map));
      return null;
    });
    final reader = Object();
    await ScreenAwakeCoordinator.instance.acquire(reader, immersiveMode: true);
    final reverseWait = LanSyncScreenAwake();
    final incoming = LanSyncScreenAwake();
    await reverseWait.close();
    expect(ScreenAwakeCoordinator.instance.holderCount, 2);
    await incoming.close();
    await incoming.close();
    expect(ScreenAwakeCoordinator.instance.holderCount, 1);
    expect(calls.last, {'keepScreenOn': true, 'immersiveMode': true});
    await ScreenAwakeCoordinator.instance.release(reader);
    expect(calls.last, {'keepScreenOn': false, 'immersiveMode': false});
  });
}
