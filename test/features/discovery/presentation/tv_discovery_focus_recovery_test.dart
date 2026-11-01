/// Remote regressions for retained loads, replaced content and long TV rails.
/// All documents are local; no source process or network is involved.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/features/discovery/application/discovery_page_controller.dart';
import 'package:mg_read/features/discovery/application/discovery_page_state.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/discovery_composite_components.dart';
import 'package:mg_read/features/discovery/presentation/discovery_destination_page.dart';
import 'package:mg_read/features/discovery/presentation/runtime_discovery_page.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focus_region.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  testWidgets('same-level TV loading retains the focused tabs and permits further movement', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [discoveryPageControllerProvider.overrideWith(_ControlledDiscovery.new)],
        child: _host(DiscoveryDestinationPage(onDestinationRequested: (_) {})),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(DiscoveryDestinationPage)));
    final controller = container.read(discoveryPageControllerProvider.notifier) as _ControlledDiscovery;
    final first = _focus(tester, find.byKey(const ValueKey('runtime-discovery-tab-0')));
    first.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(FocusManager.instance.primaryFocus, first);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 40));
    final second = FocusManager.instance.primaryFocus;
    expect(second, isNot(first));
    controller.complete();
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, second);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, first);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing focused discovery content recovers to an actionable control', (tester) async {
    await tester.pumpWidget(ProviderScope(child: _host(_page(_document))));
    await tester.pumpAndSettle();
    _focus(tester, find.byKey(const ValueKey('runtime-discovery-tab-2'))).requestFocus();
    await tester.pumpAndSettle();
    await tester.pumpWidget(ProviderScope(child: _host(_page(null))));
    await tester.pumpAndSettle();
    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNotNull);
    expect(focused, isNot(isA<FocusScopeNode>()));
    expect(focused!.canRequestFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isNot(focused));
    expect(tester.takeException(), isNull);
  });

  testWidgets('content changes cannot steal a modal dialog focus and dismiss restores navigation', (tester) async {
    await tester.pumpWidget(ProviderScope(child: _host(_page(_document))));
    await tester.pumpAndSettle();
    _focus(tester, find.byKey(const ValueKey('runtime-discovery-tab-1'))).requestFocus();
    await tester.pumpAndSettle();
    unawaited(
      showDialog<void>(
        context: tester.element(find.byType(RuntimeDiscoveryPage)),
        builder: (context) => AlertDialog(
          title: const Text('确认操作'),
          actions: [TextButton(autofocus: true, onPressed: () => Navigator.pop(context), child: const Text('返回发现'))],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dialogFocus = FocusManager.instance.primaryFocus;
    await tester.pumpWidget(ProviderScope(child: _host(_page(null))));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, dialogFocus);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(FocusManager.instance.primaryFocus, isNot(isA<FocusScopeNode>()));
    final restored = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isNot(restored));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid remote movement reaches the end of a long shelf with animated scrolling', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 450));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? opened;
    await tester.pumpWidget(
      ProviderScope(
        child: _host(
          Scaffold(
            body: TvFocusRegion(
              child: DiscoveryBookShelf(
                items: List.generate(
                  36,
                  (i) => PluginDiscoveryContentItem(content: _content(i), rank: null, metric: null, recommendation: null),
                ),
                isInBookshelf: (_) => false,
                onPressed: (content) => opened = content.id,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final first = find.ancestor(of: find.byKey(const ValueKey('runtime-discovery-cover-0')), matching: find.byType(TvFocusable)).first;
    _focus(tester, first).requestFocus();
    await tester.pumpAndSettle();
    for (var i = 0; i < 35; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 30));
      expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvFocusable>(), isNotNull);
    }
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    final during = scroll.pixels;
    await tester.pumpAndSettle();
    expect(scroll.pixels, greaterThan(during));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(opened, '35');
    expect(
      find.ancestor(of: find.byKey(const ValueKey('runtime-discovery-cover-35')), matching: find.byType(TvFocusable)).first.hitTestable(),
      findsOneWidget,
    );
    for (var i = 0; i < 35; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(opened, '0');
    expect(tester.takeException(), isNull);
  });
}

FocusNode _focus(WidgetTester tester, Finder target) =>
    tester.widget<Focus>(find.descendant(of: target, matching: find.byType(Focus)).first).focusNode!;

Widget _host(Widget child) => MaterialApp(
  theme: appTvTheme(AppTheme.dark()),
  builder: (_, child) => TvModeScope(
    enabled: true,
    onChanged: (_) {},
    child: TvRemoteShortcuts(child: child!),
  ),
  home: child,
);

RuntimeDiscoveryPage _page(PluginDiscoveryDocumentResult? document) => RuntimeDiscoveryPage(
  result: document,
  onDestinationRequested: (_) {},
  onSourcePressed: () {},
  onTabSelected: (_) {},
  onCategorySelected: (_) {},
  onContentPressed: (_) {},
  onRefreshRequested: () {},
  onLoadMore: (_) {},
  canNavigateBack: false,
  onBackRequested: () {},
  loadingCollectionId: null,
);

final _document = PluginDiscoveryDocumentResult(
  pluginId: 'tv',
  sourceName: '测试源',
  document: PluginDiscoveryDocument(
    components: [
      PluginDiscoveryTabsComponent(
        id: 'tabs',
        selectedTabId: '0',
        tabs: List.generate(4, (i) => PluginDiscoveryTab(id: '$i', label: '分类 $i', target: '$i')),
      ),
    ],
  ),
);

class _ControlledDiscovery extends DiscoveryPageController {
  static final _sources = <PluginSourceDescriptor>[
    PluginSourceDescriptor(id: 'tv', displayName: '测试源', contentKinds: [PluginContentKind.video]),
  ];
  @override
  DiscoveryPageState build() => _resolved();
  DiscoveryPageState _resolved() => DiscoveryPageState.resolved(
    sources: _sources,
    selectedSourceId: 'tv',
    result: _document,
    isEmpty: false,
    canNavigateBack: false,
    navigationDepth: 0,
    target: null,
  );
  @override
  Future<void> selectTab(String target) async {
    state = DiscoveryPageState.loadingContent(
      sources: _sources,
      selectedSourceId: 'tv',
      canNavigateBack: false,
      navigationDepth: 0,
      target: target,
      retainedParents: [_document],
    );
  }

  void complete() => state = _resolved();
}

PluginContentSummary _content(int i) => PluginContentSummary(
  id: '$i',
  title: '影片 $i',
  contentKind: PluginContentKind.video,
  author: null,
  url: null,
  coverUrl: null,
  description: null,
  language: null,
  status: PluginContentStatus.ongoing,
  access: PluginAccessKind.free,
  wordCount: null,
  chapterCount: null,
  publishedAt: null,
  updatedAt: null,
  latestChapter: null,
  categories: const [],
  tags: const [],
  attributes: const [],
);
