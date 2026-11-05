import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/library/application/library_book_visibility_changer.dart';
import 'package:mg_read/features/library/application/library_overview_loader.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';
import 'package:mg_read/features/library/presentation/private_library_page.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  testWidgets('shows a dedicated empty private shelf and returns to home', (WidgetTester tester) async {
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    addTearDown(settings.close);
    var backCount = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSettingsProvider.overrideWithValue(settings)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: PrivateLibraryPage(
            onBackRequested: () => backCount++,
            onDestinationRequested: (AppNavigationDestination destination) {},
            onReaderRequested: (String bookId) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('隐私书架'), findsOneWidget);
    expect(find.text('暂无隐私内容'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('app-nav-home')), matching: find.byIcon(Icons.visibility_off_rounded)), findsOneWidget);
    await tester.tap(find.byKey(const Key('private-library-back')));
    expect(backCount, 1);
  });

  testWidgets('distinguishes mixed media and reacts to badge and cover settings', (tester) async {
    final settings = _settings();
    await settings.initialize();
    final loader = _Loader([
      for (final kind in ContentKind.values)
        LibraryItemSummary(id: kind.code, title: '测试${kind.code}', contentKind: kind, chapterCount: 128),
    ]);
    await tester.pumpWidget(_host(settings, loader));
    await tester.pumpAndSettle();
    for (final label in ['小说', '漫画', '音频', '视频']) {
      expect(find.descendant(of: find.byType(LibraryMetadataTag), matching: find.text(label)), findsOneWidget);
    }
    expect(find.text('99+'), findsNWidgets(2));
    expect(find.byTooltip('未读128话'), findsOneWidget);

    await settings.set(AppSettingKeys.bookshelfUnreadBadgeEnabled, false);
    await settings.set(AppSettingKeys.blurredCoverBookIds, ['novel']);
    await settings.flush();
    await tester.pumpAndSettle();
    expect(find.text('99+'), findsNothing);
    final rows = tester.widgetList<LibraryBookListItem>(find.byType(LibraryBookListItem));
    expect(rows.singleWhere((row) => row.data.id == 'novel').data.isCoverBlurred, isTrue);
    expect(loader.visibilities, everyElement(LibraryVisibility.private));
  });

  testWidgets('empty shelf supports pull to refresh on a short landscape screen', (tester) async {
    tester.view.physicalSize = const Size(568, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final loader = _Loader([]);
    await tester.pumpWidget(_host(_settings(), loader, dark: true, textScale: 1.4));
    await tester.pumpAndSettle();
    final calls = loader.visibilities.length;
    await tester.drag(find.byKey(const Key('private-library-content')), const Offset(0, 280));
    await tester.pumpAndSettle();
    expect(loader.visibilities.length, greaterThan(calls));
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps restore feedback visible after the last item leaves', (tester) async {
    final loader = _Loader([_book]);
    final changer = _Changer(() async => loader.items.clear());
    await tester.pumpWidget(_host(_settings(), loader, changer: changer));
    await tester.pumpAndSettle();
    await _restore(tester);
    expect(find.text('暂无隐私内容'), findsOneWidget);
    expect(find.text('已取消《测试内容》的隐私设置'), findsOneWidget);
    expect(changer.calls, 1);
    await tester.tap(find.byTooltip('关闭提示'));
    await tester.pumpAndSettle();
    expect(find.text('已取消《测试内容》的隐私设置'), findsNothing);
  });

  testWidgets('restores the row and shows feedback when persistence fails', (tester) async {
    final loader = _Loader([_book]);
    final changer = _Changer(() async => throw StateError('save failed'));
    await tester.pumpWidget(_host(_settings(), loader, changer: changer));
    await tester.pumpAndSettle();
    await _restore(tester);
    expect(find.byType(LibraryBookListItem), findsOneWidget);
    expect(find.text('取消隐私未能完成，请稍后刷新。'), findsOneWidget);
  });

  testWidgets('retains books on refresh failure and offers a working retry', (tester) async {
    final loader = _Loader([_book]);
    await tester.pumpWidget(_host(_settings(), loader));
    await tester.pumpAndSettle();
    loader.fail = true;
    await tester.drag(find.byKey(const Key('private-library-content')), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryBookListItem), findsOneWidget);
    expect(find.text('刷新失败，仍显示上次加载的内容。'), findsOneWidget);
    loader.fail = false;
    await tester.tap(find.byTooltip('重试刷新'));
    await tester.pumpAndSettle();
    expect(find.text('刷新失败，仍显示上次加载的内容。'), findsNothing);
  });

  testWidgets('finishes restore safely after leaving the private shelf', (tester) async {
    final completion = Completer<void>();
    final loader = _Loader([_book]);
    await tester.pumpWidget(_host(_settings(), loader, changer: _Changer(() => completion.future)));
    await tester.pumpAndSettle();
    await _restore(tester);
    await tester.pumpWidget(const SizedBox());
    completion.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('builds long shelves lazily and opens the original item', (tester) async {
    final loader = _Loader(List.generate(200, (index) => LibraryItemSummary(id: '$index', title: '条目$index')));
    String? opened;
    await tester.pumpWidget(_host(_settings(), loader, onOpen: (id) => opened = id));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryBookListItem).evaluate().length, lessThan(30));
    await tester.tap(find.byType(LibraryBookListItem).first);
    expect(opened, '0');
  });
}

const _book = LibraryItemSummary(id: 'private-book', title: '测试内容');

AppSettingsManager _settings() {
  final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
  addTearDown(settings.close);
  return settings;
}

Widget _host(
  AppSettingsManager settings,
  _Loader loader, {
  _Changer? changer,
  bool dark = false,
  double textScale = 1,
  ValueChanged<String>? onOpen,
}) => ProviderScope(
  overrides: [
    appSettingsProvider.overrideWithValue(settings),
    libraryOverviewLoaderProvider.overrideWithValue(loader),
    if (changer != null) libraryBookVisibilityChangerProvider.overrideWithValue(changer),
  ],
  child: MaterialApp(
    theme: dark ? AppTheme.dark() : AppTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: PrivateLibraryPage(onBackRequested: () {}, onDestinationRequested: (_) {}, onReaderRequested: onOpen ?? (_) {}),
  ),
);

Future<void> _restore(WidgetTester tester) async {
  await tester.tap(find.byTooltip('书籍更多操作'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('取消隐私'));
  await tester.pumpAndSettle();
}

class _Loader implements LibraryOverviewLoader {
  _Loader(this.items);
  final List<LibraryItemSummary> items;
  final visibilities = <LibraryVisibility>[];
  bool fail = false;
  @override
  Future<LibraryOverview> load({LibraryVisibility visibility = LibraryVisibility.normal}) async {
    visibilities.add(visibility);
    if (fail) throw StateError('load failed');
    return LibraryOverview(items: visibility == LibraryVisibility.private ? [...items] : []);
  }
}

class _Changer implements LibraryBookVisibilityChanger {
  _Changer(this.change);
  final Future<void> Function() change;
  int calls = 0;
  @override
  Future<void> setBookVisibility(String bookId, LibraryVisibility visibility) {
    calls++;
    expect(visibility, LibraryVisibility.normal);
    return change();
  }
}
