/// Workspace navigation, discovery projections and accessible layouts.
/// In-memory stores isolate host IO; optional captures render production pages.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';
import 'package:mg_read/features/lan_sync/application/paired_device_repository.dart';
import 'package:mg_read/features/tv_companion/application/companion_controller.dart';
import 'package:mg_read/features/tv_companion/data/companion_repository.dart';
import 'package:mg_read/features/tv_companion/domain/companion_models.dart';
import 'package:mg_read/features/tv_companion/presentation/companion_devices_view.dart';
import 'package:mg_read/features/tv_companion/presentation/companion_page.dart';
import 'package:mg_read/features/tv_companion/presentation/companion_receiver_view.dart';
import 'package:mg_read/features/tv_companion/presentation/companion_widgets.dart';

import '../../../support/visual_evidence.dart';
import '../application/companion_controller_testkit.dart';

const _captureDirectory = String.fromEnvironment('TV_COMPANION_CAPTURE_DIR');

void main() {
  setUp(
    () => PackageInfo.setMockInitialValues(
      appName: 'MgRead',
      packageName: 'mg_read.test',
      version: '0.1.0',
      buildNumber: '1',
      buildSignature: '',
    ),
  );

  testWidgets('discovery filters expired and non-receiving devices and gates offline tabs', (tester) async {
    final container = await _mount(tester);
    final service = container.read(companionControllerProvider);
    for (final target in [
      ('客厅电视', true, const Duration(minutes: 2)),
      ('手机', false, const Duration(minutes: 2)),
      ('过期设备', true, const Duration(seconds: -1)),
    ]) {
      service.discovered(
        deviceId: target.$1,
        label: target.$1,
        address: '192.168.1.20',
        port: 43521,
        lifetime: target.$3,
        services: {'companion': 1, 'receiving': target.$2},
      );
    }
    await tester.pumpAndSettle();
    expect(find.text('客厅电视'), findsOneWidget);
    expect(find.text('手机'), findsNothing);
    expect(find.text('过期设备'), findsNothing);

    await tester.tap(find.byKey(const Key('companion-tab-1')));
    await tester.pumpAndSettle();
    expect(find.text('把手机变成 TV 遥控器'), findsOneWidget);
    expect(find.byTooltip('播放'), findsNothing);
    await tester.tap(find.text('去连接 TV'));
    await tester.pumpAndSettle();
    expect(find.text('客厅电视'), findsOneWidget);

    await tester.tap(find.byKey(const Key('companion-tab-2')));
    await tester.pumpAndSettle();
    expect(find.text('用手机找片，在电视上看'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual, help and tools stay reachable in short landscape with large text', (tester) async {
    var syncOpened = 0;
    await _mount(tester, size: const Size(568, 320), scale: 1.6, onSync: () async => syncOpened++);
    final manual = find.byKey(const Key('companion-manual'));
    await tester.scrollUntilVisible(manual, 160);
    await tester.pumpAndSettle();
    await tester.tap(manual);
    await tester.pumpAndSettle();
    expect(find.text('手动连接 TV'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('还是找不到 TV？'), 160);
    await tester.pumpAndSettle();
    await tester.tap(find.text('还是找不到 TV？'));
    await tester.pumpAndSettle();
    expect(find.textContaining('访客 Wi-Fi'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('companion-sync')), 160);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion-sync')));
    await tester.pumpAndSettle();
    expect(syncOpened, 1);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('empty workspace renders in ${dark ? 'dark' : 'light'} theme at phone width', (tester) async {
      await _mount(tester, dark: dark, size: const Size(400, 892));
      expect(find.text('还没有发现电视'), findsOneWidget);
      await _capture(tester, dark ? 'devices-dark' : 'devices-light');
      await tester.tap(find.byKey(const Key('companion-tab-1')));
      await tester.pumpAndSettle();
      await _capture(tester, dark ? 'remote-offline-dark' : 'remote-offline-light');
      await tester.tap(find.byKey(const Key('companion-tab-2')));
      await tester.pumpAndSettle();
      await _capture(tester, dark ? 'catalog-offline-dark' : 'catalog-offline-light');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('connected workspace opens remote and loads TV sources without a playback command', (tester) async {
    final fixture = await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(() async {
        final pair = await CompanionPairFixture.create();
        try {
          await pair.connect(label: '客厅电视');
          return pair;
        } on Object {
          await pair.close();
          rethrow;
        }
      }, _RealHttpOverrides()),
    );
    expect(fixture, isNotNull);
    addTearDown(() => fixture!.close());
    await _mount(tester, existingContainer: fixture!.phoneContainer);
    expect(find.text('客厅电视'), findsOneWidget);
    await _capture(tester, 'devices-connected');
    await tester.tap(find.byKey(const Key('companion-tab-1')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('播放'), findsOneWidget);
    await _capture(tester, 'remote-connected');
    await tester.tap(find.byKey(const Key('companion-tab-2')));
    await _settleServices(tester);
    expect(find.text('TV 暂无可用影视来源，请先在电视上安装或启用数据源。'), findsOneWidget);
    expect(fixture.phone.lastReceipt, isNull);
    await _capture(tester, 'catalog-connected');
  });

  testWidgets('connected card routes actions and passes exact discovered endpoint', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final current = _endpoint('current', '客厅电视');
    final other = _endpoint('other', '卧室的电视，名称特别长也需要完整显示');
    CompanionEndpoint? selected;
    var remote = 0, catalog = 0, disconnected = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
            child: CompanionDevicesView(
              endpoints: [current, other],
              status: CompanionConnectionStatus.connected,
              selectedId: current.deviceId,
              selectedLabel: current.label,
              stale: true,
              busy: false,
              discovering: true,
              onRefresh: () {},
              onManual: () {},
              onConnect: (endpoint) => selected = endpoint,
              onDisconnect: () => disconnected++,
              onRemote: () => remote++,
              onCatalog: () => catalog++,
              tools: CompanionTools(onHistory: () {}, onSync: () {}),
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('状态更新延迟', findRichText: true), findsOneWidget);
    expect(find.byKey(const Key('companion-connect-current')), findsNothing);
    for (final action in ['打开遥控', '去 TV 找片', '断开连接']) {
      await tester.ensureVisible(find.text(action));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
    }
    expect((remote, catalog, disconnected), (1, 1, 1));
    await tester.scrollUntilVisible(find.byKey(const Key('companion-connect-other')), 160);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion-connect-other')));
    expect(selected, same(other));
    expect(tester.takeException(), isNull);
  });

  testWidgets('busy discovery prevents duplicate actions and exposes retry after failure', (tester) async {
    Widget view({required bool busy, String? error}) => MaterialApp(
      home: Scaffold(
        body: CompanionDevicesView(
          endpoints: const [],
          status: CompanionConnectionStatus.disconnected,
          selectedId: null,
          selectedLabel: 'TV',
          stale: true,
          busy: busy,
          discovering: false,
          error: error,
          onRefresh: () {},
          onManual: () {},
          onConnect: (_) {},
          onDisconnect: () {},
          onRemote: () {},
          onCatalog: () {},
          tools: const SizedBox(),
        ),
      ),
    );
    await tester.pumpWidget(view(busy: true));
    expect(find.text('正在寻找局域网中的 TV'), findsOneWidget);
    expect(tester.widget<IconButton>(find.byKey(const Key('companion-refresh'))).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(find.byKey(const Key('companion-manual'))).onPressed, isNull);
    await tester.pumpWidget(view(busy: false, error: '需要本地网络权限。'));
    expect(find.text('需要本地网络权限。'), findsOneWidget);
    expect(tester.widget<IconButton>(find.byKey(const Key('companion-refresh'))).onPressed, isNotNull);
  });

  testWidgets('receiver exposes its transient LAN address for manual connection', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: CompanionReceiverView(
            enabled: true,
            label: '客厅电视',
            addresses: const ['192.168.1.20:43521'],
            controllers: const ['手机'],
            tools: CompanionTools(onHistory: () {}, onSync: () {}),
          ),
        ),
      ),
    );
    final copy = find.byTooltip('复制地址');
    await tester.scrollUntilVisible(copy, 120, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(copied, '192.168.1.20:43521');
    expect(find.text('TV 地址已复制'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

CompanionEndpoint _endpoint(String id, String label) =>
    CompanionEndpoint(deviceId: id, label: label, address: '192.168.1.20', port: 43521, expiresAt: DateTime(2100), receiving: true);

final class _RealHttpOverrides extends HttpOverrides {}

Future<ProviderContainer> _mount(
  WidgetTester tester, {
  Size size = const Size(400, 892),
  double scale = 1,
  bool dark = false,
  Future<void> Function()? onSync,
  ProviderContainer? existingContainer,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  if (_captureDirectory.isNotEmpty) await loadVisualEvidenceFonts();
  final container =
      existingContainer ??
      ProviderContainer(
        overrides: [
          deviceIdentityStoreProvider.overrideWithValue(CompanionTestIdentityStore('phone-test', '手机')),
          pairedDeviceRepositoryProvider.overrideWithValue(CompanionTestPairedDevices()),
          companionRepositoryProvider.overrideWithValue(MemoryCompanionRepository()),
          companionNetworkProvider.overrideWithValue(const CompanionTestNetwork()),
          companionOpenDeviceSyncProvider.overrideWithValue(onSync ?? () async {}),
        ],
      );
  await tester.runAsync(() async {
    await container.read(companionControllerProvider).initialize();
    await container.read(deviceSyncControllerProvider.notifier).start();
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    if (existingContainer == null) container.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: visualEvidenceHost(
        MaterialApp(
          theme: dark ? AppTheme.dark() : AppTheme.light(),
          debugShowCheckedModeBanner: false,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale), padding: const EdgeInsets.only(bottom: 24)),
            child: child!,
          ),
          home: const CompanionPage(),
        ),
      ),
    ),
  );
  await _settleServices(tester);
  return container;
}

Future<void> _settleServices(WidgetTester tester) async {
  // App-lifetime services and real sockets complete outside the widget clock.
  // Drain each awaited phase before asking the fake clock to settle animations.
  for (var attempt = 0; attempt < 8; attempt++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
  }
  expect(find.byType(LinearProgressIndicator), findsNothing, reason: 'Discovery startup must finish before layout assertions.');
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (_captureDirectory.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(visualEvidenceBoundaryKey));
  await tester.runAsync(() async {
    final rendered = await boundary.toImage(pixelRatio: 1);
    final png = await rendered.toByteData(format: ui.ImageByteFormat.png);
    rendered.dispose();
    final file = File('$_captureDirectory/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(png!.buffer.asUint8List());
  });
}
