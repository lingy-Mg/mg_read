/// 三种业务二维码的明暗主题、扫码对比度、矩阵和窄屏回归。
/// 可用 --dart-define=LAN_SYNC_QR_PREVIEW=true 将真实组件预览写入忽略目录供视觉验收。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/application/app_transfer_controller.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';
import 'package:mg_read/features/lan_sync/domain/app_transfer_qr_payload.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';
import 'package:mg_read/features/lan_sync/domain/lan_pairing_payload.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_qr_payload.dart';
import 'package:mg_read/features/lan_sync/presentation/app_transfer_widgets.dart';
import 'package:mg_read/features/lan_sync/presentation/lan_sync_page.dart';
import 'package:mg_read/features/lan_sync/presentation/paired_device_widgets.dart';

const _previewKey = Key('qr-preview');
const _exportPreviews = bool.fromEnvironment('LAN_SYNC_QR_PREVIEW');

void main() {
  setUpAll(() async {
    final font = FontLoader('packages/novel_reader_ui/MiSans')
      ..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'));
    await font.load();
  });

  final themes = <String, ThemeData>{
    for (final color in AppThemeColor.values) 'light-${color.id}': AppTheme.light(color: color),
    for (final color in AppDarkThemeColor.values) 'dark-${color.id}': AppTheme.dark(color: color),
  };
  final syncOffer = LanSyncConnectionOffer(
    sessionId: 'session_12345678',
    port: 47231,
    addresses: const <String>['192.168.1.20', '10.10.0.8'],
  );
  final appOffer = AppTransferConnectionOffer(sessionId: 'app_session_12345678', port: 47232, addresses: const <String>['192.168.1.20']);
  final pairingOffer = LanPairingOffer(
    addresses: const <String>['192.168.1.20', '10.10.0.8'],
    deviceId: 'desktop_device_123456',
    label: '开发电脑',
    port: 47233,
    secret: List<int>.filled(32, 1),
    sessionId: 'pairing_session_123456',
  );
  final scenes = <({String name, String payload, Key qrKey, String label, Widget child})>[
    (
      name: 'data',
      payload: LanSyncQrPayload.encode(syncOffer),
      qrKey: const Key('lan-sync-sender-qr'),
      label: 'MgRead 局域网同步二维码',
      child: LanSyncConnectionQrCard(offer: syncOffer),
    ),
    (
      name: 'app',
      payload: AppTransferQrPayload.encode(appOffer),
      qrKey: const Key('app-transfer-sender-qr'),
      label: 'MgRead App 传输二维码',
      child: AppTransferPanel(
        state: AppTransferState(
          role: AppTransferRole.sender,
          phase: AppTransferPhase.waitingForPeer,
          connectionOffer: appOffer,
          localVersion: const AppVersionInfo(platform: AppUpdatePlatform.android, version: '0.25.4', buildNumber: 425),
          message: '等待对方扫码',
        ),
        onScanQr: () {},
        onInstall: (_) {},
        onCancel: () {},
        onReset: () {},
      ),
    ),
    (
      name: 'pairing',
      payload: LanPairingQrPayload.encode(pairingOffer),
      qrKey: const Key('device-sync-pairing-qr'),
      label: 'MgRead 设备配对二维码',
      child: DevicePairingSheet(
        state: DeviceSyncState(pairingPhase: DevicePairingPhase.showingOffer, pairingOffer: pairingOffer),
        onBeginPairing: () {},
        onApprovePairing: () {},
        onRejectPairing: () {},
        onCancelPairing: () {},
      ),
    ),
  ];

  for (final theme in themes.entries) {
    for (final scene in scenes) {
      testWidgets('${theme.key} ${scene.name} renders a complete dark-on-light QR with a quiet zone', (tester) async {
        _setViewport(tester, const Size(360, 800));
        await tester.pumpWidget(_host(theme.value, scene.child));
        await tester.pump();

        final qrFinder = find.byKey(scene.qrKey);
        final qr = tester.widget<QrImageView>(qrFinder);
        final background = qr.backgroundColor;
        final ink = qr.dataModuleStyle.color!;
        expect(background.a, 1);
        expect(background.computeLuminance(), greaterThan(0.9));
        expect(ink.a, 1);
        expect((background.computeLuminance() + 0.05) / (ink.computeLuminance() + 0.05), greaterThan(7));
        expect(qr.eyeStyle.color, ink);
        final semantics = tester.ensureSemantics();
        await tester.pump();
        try {
          expect(find.bySemanticsLabel(scene.label), findsOneWidget);
        } finally {
          semantics.dispose();
        }

        final matrix = QrImage(QrCode.fromData(data: scene.payload, errorCorrectLevel: QrErrorCorrectLevel.M));
        final rect = tester.getRect(qrFinder);
        final moduleSize = (rect.width - qr.padding.horizontal) / matrix.moduleCount;
        expect(qr.padding.left, greaterThanOrEqualTo(moduleSize * 4));
        expect(qr.padding, EdgeInsets.all(qr.padding.left));
        expect(tester.takeException(), isNull);

        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_previewKey));
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          try {
            final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
            var mismatches = 0;
            final samples = <String>[];
            // 检查完整矩阵及四模块白色静区，覆盖实际绘制而不只断言组件参数。
            for (var row = -4; row < matrix.moduleCount + 4; row++) {
              for (var col = -4; col < matrix.moduleCount + 4; col++) {
                final x = (rect.left + qr.padding.left + (col + 0.5) * moduleSize).floor();
                final y = (rect.top + qr.padding.top + (row + 0.5) * moduleSize).floor();
                final offset = (y * image.width + x) * 4;
                final inside = row >= 0 && col >= 0 && row < matrix.moduleCount && col < matrix.moduleCount;
                final expected = inside && matrix.isDark(row, col) ? ink : background;
                final actual = Color.fromARGB(
                  bytes.getUint8(offset + 3),
                  bytes.getUint8(offset),
                  bytes.getUint8(offset + 1),
                  bytes.getUint8(offset + 2),
                );
                if (actual.toARGB32() != expected.toARGB32()) {
                  mismatches++;
                  if (samples.length < 4) samples.add('$row,$col at $x,$y: $actual expected $expected');
                }
              }
            }
            if (_exportPreviews) {
              final file = File('.dart_tool/qr-previews/${theme.key}-${scene.name}.png');
              await file.parent.create(recursive: true);
              final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
              await file.writeAsBytes(png.buffer.asUint8List());
            }
            expect(mismatches, 0, reason: 'QR matrix and quiet zone must survive the current theme: $rect $moduleSize $samples');
          } finally {
            image.dispose();
          }
        });
      });
    }
  }

  for (final scene in scenes) {
    testWidgets('${scene.name} fits a narrow dark screen with large text', (tester) async {
      _setViewport(tester, const Size(280, 800));
      await tester.pumpWidget(_host(AppTheme.dark(), scene.child, textScale: 2));
      await tester.pump();
      final rect = tester.getRect(find.byKey(scene.qrKey));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(280));
      expect(rect.width, rect.height);
      expect(tester.takeException(), isNull);
    });
  }
}

Widget _host(ThemeData theme, Widget child, {double textScale = 1}) => RepaintBoundary(
  key: _previewKey,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    home: Scaffold(
      body: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: SingleChildScrollView(padding: const EdgeInsets.all(AppSpacing.comfortable), child: child),
        ),
      ),
    ),
  ),
);

void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
