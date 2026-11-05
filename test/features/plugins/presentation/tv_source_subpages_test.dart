/// TV 子页面截图、分区导航和长正文确认回归。使用真实 Widget 与窄端口替身。
/// 不启动 Runtime，不写入真实插件或缓存，不替代电视设备验收。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/application/plugin_cache_manager.dart';
import 'package:mg_read/features/plugins/application/source_collection_import.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_source_detail_page.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_health_page.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_help_page.dart';
import 'package:mg_read/features/plugins/presentation/plugin_cache_management_page.dart';
import 'package:mg_read/features/plugins/presentation/data_source_management_sheets.dart';
import 'package:mg_read/features/plugins/presentation/source_collection_import_sheet.dart';
import 'package:mg_read/features/plugins/presentation/source_management_tv.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import '../../../app/mg_read_app_test_support.dart';
import 'plugin_runtime_status_page_fixture.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'packages/novel_reader_ui/MiSans',
    )..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets('TV detail separates commands from metadata and preserves focus after full value', (tester) async {
    _viewport(tester);
    await tester.pumpWidget(
      _host(PluginRuntimeSourceDetailPage(pluginId: 'org.mgread.qidian', onBackRequested: () {}, onVerificationRequested: (_) {})),
    );
    await tester.pumpAndSettle();
    await _golden(tester, 'tv_source_detail_dark');
    _focus(tester, 'data-source-detail-version').requestFocus();
    await tester.pumpAndSettle();
    await _key(tester, LogicalKeyboardKey.select);
    expect(find.byKey(const Key('data-source-detail-full-version')), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.select);
    expect(_focus(tester, 'data-source-detail-version').hasFocus, isTrue);
  });

  testWidgets('TV health and help expose independent sections and advanced controls', (tester) async {
    _viewport(tester);
    await tester.pumpWidget(_host(PluginRuntimeHealthPage(onBackRequested: () {})));
    await tester.pumpAndSettle();
    await _golden(tester, 'tv_source_health_dark');
    _focus(tester, 'tv-source-section-health').requestFocus();
    await tester.pumpAndSettle();
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.select);
    expect(find.text('内存占用'), findsNWidgets(2));
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.select);
    expect(find.text('起点中文网'), findsOneWidget);
    await tester.pumpWidget(_host(const PluginRuntimeHelpPage()));
    await tester.pumpAndSettle();
    await _golden(tester, 'tv_source_help_dark');
    _focus(tester, 'tv-source-section-guide').requestFocus();
    await tester.pumpAndSettle();
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.select);
    expect(find.byKey(const Key('runtime-debug-http-toggle')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV installation chooser update confirmation and result are complete review surfaces', (tester) async {
    _viewport(tester);
    await _dialog(tester, (context) => showDataSourceImportSheet(context));
    await _golden(tester, 'tv_source_import_choices_dark');
    await _key(tester, LogicalKeyboardKey.escape);
    bool? accepted;
    await _dialog(tester, (context) async => accepted = await showSourceUpdatesConfirmationDialog(context, _candidates));
    await _golden(tester, 'tv_source_update_review_dark');
    await _key(tester, LogicalKeyboardKey.select);
    expect(accepted, isFalse);
    await _dialog(
      tester,
      (context) => showSourceCollectionImportResults(
        context,
        [
          const PluginTransferImportResult(pluginId: 'video-one', status: PluginTransferImportStatus.installed, version: '2.0.0'),
          const PluginTransferImportResult(pluginId: 'audio-one', status: PluginTransferImportStatus.failed, version: '2.0.0'),
        ],
        _candidates,
        onlineRepository: true,
        pendingPluginIds: {'video-one'},
      ),
    );
    await _golden(tester, 'tv_source_import_result_dark');
    await _key(tester, LogicalKeyboardKey.select);
    expect(find.text('在线数据源安装部分失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short TV confirmation defaults to cancel and scrolls the entire long body', (tester) async {
    _viewport(tester, const Size(640, 360));
    bool? confirmed;
    Future<void> open(BuildContext context) async {
      confirmed = await showSourceManagementDialog<bool>(
        context: context,
        builder: (context) => SourceManagementDialog(
          title: const Text('确认批量操作'),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < 25; i++) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('操作说明 $i')),
              const Text('末尾信息'),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('确认')),
          ],
        ),
      );
    }

    await _dialog(tester, open, scale: 1.6);
    await _key(tester, LogicalKeyboardKey.select);
    expect(confirmed, isFalse);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await _key(tester, LogicalKeyboardKey.arrowUp);
    for (var i = 0; i < 40; i++) {
      await _key(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(find.text('末尾信息').hitTestable(), findsOneWidget);
    expect(find.text('取消').hitTestable(), findsOneWidget);
    await _golden(tester, 'tv_source_confirmation_short');
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV cache review keeps bulk action visible and cancellation never clears data', (tester) async {
    _viewport(tester);
    final cache = _CacheGateway();
    await tester.pumpWidget(
      _host(
        PluginCacheManagementPage(onBackRequested: () {}, onDestinationRequested: (_) {}),
        cache: cache,
      ),
    );
    await tester.pumpAndSettle();
    await _golden(tester, 'tv_source_cache_dark');
    _focus(tester, 'plugin-cache-clear-all').requestFocus();
    await tester.pumpAndSettle();
    await _key(tester, LogicalKeyboardKey.select);
    await _key(tester, LogicalKeyboardKey.select);
    expect(cache.clears, 0);
    expect(_focus(tester, 'plugin-cache-clear-all').hasFocus, isTrue);
  });

  testWidgets('short large-text TV sections remain navigable and review footers stay visible', (tester) async {
    _viewport(tester, const Size(640, 360));
    await tester.pumpWidget(_host(const PluginRuntimeHelpPage(), scale: 1.6));
    await tester.pumpAndSettle();
    _focus(tester, 'tv-source-section-guide').requestFocus();
    await tester.pumpAndSettle();
    await _key(tester, LogicalKeyboardKey.arrowRight);
    await _key(tester, LogicalKeyboardKey.select);
    expect(find.text('返回').hitTestable(), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.select);
    _focus(tester, 'tv-source-section-advanced').requestFocus();
    await tester.pumpAndSettle();
    await _key(tester, LogicalKeyboardKey.select);
    for (var i = 0; i < 12; i++) {
      await _key(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(tester.takeException(), isNull);
    await _dialog(tester, (context) => showSourceUpdatesConfirmationDialog(context, _candidates), scale: 1.6);
    expect(find.byKey(const Key('source-updates-confirm-overwrite')).hitTestable(), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.select);
    await _dialog(
      tester,
      (context) => showSourceCollectionImportResults(context, [
        const PluginTransferImportResult(pluginId: 'video-one', status: PluginTransferImportStatus.installed, version: '2.0.0'),
      ], _candidates),
      scale: 1.6,
    );
    expect(find.byKey(const Key('tv-source-import-result-close')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _host(Widget child, {double scale = 1, _CacheGateway? cache}) => ProviderScope(
  overrides: [
    pluginRuntimeGatewayProvider.overrideWithValue(const TestReadyPluginRuntimeGateway()),
    pluginRuntimeConnectionProvider.overrideWith((ref) async => dataSourceManagementFixture),
    pluginRuntimeStatusProvider.overrideWith(
      (ref) async => PluginRuntimeStatus(
        arch: 'arm64',
        isHealthy: true,
        memory: const PluginRuntimeMemory(arrayBuffers: 1024, external: 2097152, heapTotal: 16777216, heapUsed: 8388608, rss: 67108864),
        nodeVersion: '26.10.0',
        platform: 'android',
        plugins: dataSourceManagementFixture.plugins,
        runtimeVersion: '0.2.0',
        runtimeKind: 'android-javet',
        uptime: const Duration(minutes: 12),
      ),
    ),
    if (cache != null) pluginCacheGatewayProvider.overrideWithValue(cache),
  ],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: appTvTheme(AppTheme.dark()),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: TvModeScope(enabled: true, onChanged: (_) {}, child: child!),
    ),
    home: child,
  ),
);

Future<void> _dialog(WidgetTester tester, Future<Object?> Function(BuildContext) open, {double scale = 1}) async {
  await tester.pumpWidget(
    _host(
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(onPressed: () => open(context), child: const Text('打开')),
        ),
      ),
      scale: scale,
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void _viewport(WidgetTester tester, [Size size = const Size(1280, 720)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

FocusNode _focus(WidgetTester tester, String key) =>
    tester.widget<Focus>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Focus)).first).focusNode!;
Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

Future<void> _golden(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
}

final _candidates = [
  for (final (id, name) in [('video-one', '影视数据源'), ('audio-one', '听书数据源')])
    SourceCollectionCandidate(
      plugin: SourceCollectionPlugin(
        id: id,
        name: name,
        version: '2.0.0',
        format: 'singleFile',
        byteLength: 3,
        checksum: '00000000',
        openBytes: () => Stream.value([1, 2, 3]),
      ),
      plan: PluginTransferPlanItem(action: PluginTransferPlanAction.upgrade, pluginId: id, receiverVersion: '1.0.0', version: '2.0.0'),
    ),
];

class _CacheGateway implements PluginCacheGateway {
  int clears = 0;
  @override
  Future<List<PluginCacheUsage>> listUsage() async => [];
  @override
  Future<PluginCacheUsage> usageForPlugin(String pluginId) async => PluginCacheUsage(pluginId: pluginId, bytes: 2048);
  @override
  Future<PluginCacheClearResult> clearAll() async {
    clears++;
    return const PluginCacheClearResult(items: []);
  }

  @override
  Future<PluginCacheClearResult> clearPlugin(String pluginId) => clearAll();
}
