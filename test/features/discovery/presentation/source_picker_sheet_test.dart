import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/source_picker_sheet.dart';

void main() {
  final sources = <PluginSourceDescriptor>[
    PluginSourceDescriptor(
      id: 'org.mgread.aisishuwu',
      displayName: '爱丽丝书屋',
      description: '成人向原创网络小说数据源。',
      contentKinds: const <PluginContentKind>[PluginContentKind.novel],
    ),
    PluginSourceDescriptor(
      id: 'org.example.manga',
      displayName: '示例漫画源',
      iconUrl: 'http://127.0.0.1:1/v1/plugin-icon/picker-test-token',
      contentKinds: const <PluginContentKind>[PluginContentKind.manga],
    ),
  ];

  testWidgets('picker searches, selects and marks the current source', (tester) async {
    DiscoverySourcePickerResult? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  result = await showDiscoverySourcePicker(context, sources: sources, selectedSourceId: 'org.mgread.aisishuwu');
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('选择数据源'), findsOneWidget);
    expect(find.text('可用'), findsNothing);
    expect(find.text('最近使用'), findsNothing);
    expect(find.text('全部'), findsNothing);
    expect(find.text('已启用'), findsNothing);
    expect(find.text('成人向原创网络小说数据源。'), findsOneWidget);
    expect(find.text('2 个数据源 · 当前：爱丽丝书屋'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.byKey(const Key('discovery-source-picker-search')), findsNothing);
    expect(find.byKey(const Key('discovery-source-picker-filters')), findsNothing);
    expect(find.byKey(const Key('discovery-source-picker-filter-count-可用')), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(const Key('discovery-source-picker-search-toggle'))).dx,
      lessThan(tester.getTopLeft(find.byKey(const Key('discovery-source-picker-close'))).dx),
    );
    expect(find.byKey(const ValueKey<String>('discovery-source-picker-actions-org.mgread.aisishuwu')), findsOneWidget);
    final Image image = tester.widget<Image>(find.byKey(const Key('source-icon-network-org.example.manga')));
    expect(
      image.image,
      isA<NetworkImage>().having((NetworkImage provider) => provider.url, 'url', 'http://127.0.0.1:1/v1/plugin-icon/picker-test-token'),
    );
    await tester.tap(find.byKey(const Key('discovery-source-picker-search-toggle')));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('discovery-source-picker-search'))).height, 46);
    await tester.enterText(find.byKey(const Key('discovery-source-picker-search')), '漫画');
    await tester.pump();

    expect(find.text('爱丽丝书屋'), findsNothing);
    expect(find.byKey(const Key('discovery-source-picker-search-clear')), findsOneWidget);
    await tester.tap(find.byKey(const Key('discovery-source-picker-search-clear')));
    await tester.pump();
    expect(find.text('爱丽丝书屋'), findsOneWidget);
    expect(find.byKey(const Key('discovery-source-picker-search-clear')), findsNothing);
    await tester.enterText(find.byKey(const Key('discovery-source-picker-search')), '漫画');
    await tester.pump();
    await tester.tap(find.byKey(const Key('discovery-source-picker-search-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('discovery-source-picker-search')), findsNothing);
    expect(find.text('爱丽丝书屋'), findsOneWidget);
    await tester.tap(find.byKey(const Key('discovery-source-picker-search-toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('discovery-source-picker-search')), '漫画');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('discovery-source-picker-org.example.manga')));
    await tester.pumpAndSettle();

    expect(result, isA<DiscoverySourceSelected>());
    expect((result! as DiscoverySourceSelected).sourceId, 'org.example.manga');
  });

  testWidgets('picker exposes the all-source search scope', (tester) async {
    DiscoverySourcePickerResult? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDiscoverySourcePicker(context, sources: sources, selectedSourceId: null, allowAllSources: true);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('discovery-source-picker-all')), findsOneWidget);
    expect(find.text('并行搜索并合并重复结果'), findsOneWidget);

    await tester.tap(find.byKey(const Key('discovery-source-picker-all')));
    await tester.pumpAndSettle();
    expect(result, isA<DiscoveryAllSourcesSelected>());
  });

  testWidgets('picker exposes the Runtime-owned management entry point', (tester) async {
    DiscoverySourcePickerResult? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDiscoverySourcePicker(context, sources: sources, selectedSourceId: 'org.mgread.aisishuwu');
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discovery-source-picker-manage')));
    await tester.pumpAndSettle();

    expect(result, isA<DiscoverySourceManagementRequested>());
  });

  testWidgets('picker presents management as secondary and add as primary', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDiscoverySourcePicker(context, sources: sources, selectedSourceId: sources.first.id),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(OutlinedButton, '管理数据源'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '添加数据源'), findsOneWidget);
  });

  testWidgets('picker constrains its width on wide layouts', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDiscoverySourcePicker(context, sources: sources, selectedSourceId: sources.first.id),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byKey(const Key('discovery-source-picker-panel'))).width, 520);
  });

  testWidgets('long press exposes source WebView debug actions', (tester) async {
    DiscoverySourcePickerResult? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDiscoverySourcePicker(context, sources: sources, selectedSourceId: 'org.mgread.aisishuwu');
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey<String>('discovery-source-picker-org.mgread.aisishuwu')));
    await tester.pumpAndSettle();

    expect(find.text('进入 WebView 调试'), findsOneWidget);
    expect(find.text('显示 WebView'), findsOneWidget);
    await tester.tap(find.text('进入 WebView 调试'));
    await tester.pumpAndSettle();

    expect(result, isA<DiscoverySourceWebViewActionRequested>());
    expect((result! as DiscoverySourceWebViewActionRequested).sourceId, 'org.mgread.aisishuwu');
    expect((result! as DiscoverySourceWebViewActionRequested).action, DiscoverySourceWebViewAction.enterDebug);
  });

  testWidgets('picker orders available sources by display name after pinned sources', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDiscoverySourcePicker(
              context,
              sources: <PluginSourceDescriptor>[sources[1], sources[0]],
              selectedSourceId: 'org.mgread.aisishuwu',
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.byKey(const ValueKey<String>('discovery-source-picker-org.mgread.aisishuwu'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey<String>('discovery-source-picker-org.example.manga'))).dy),
    );
  });

  testWidgets('picker pins a source, persists the callback and moves it to the top', (tester) async {
    final pinnedSourceIds = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDiscoverySourcePicker(
              context,
              sources: sources,
              selectedSourceId: 'org.mgread.aisishuwu',
              pinnedSourceIds: pinnedSourceIds,
              onPinChanged: (sourceId, pinned) async {
                pinnedSourceIds.remove(sourceId);
                if (pinned) pinnedSourceIds.insert(0, sourceId);
              },
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('discovery-source-picker-pin-org.example.manga')));
    await tester.pumpAndSettle();

    expect(pinnedSourceIds, <String>['org.example.manga']);
    expect(find.text('已置顶'), findsOneWidget);
    expect(find.text('其他数据源'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey<String>('discovery-source-picker-org.example.manga'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey<String>('discovery-source-picker-org.mgread.aisishuwu'))).dy),
    );
    expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
  });
}
