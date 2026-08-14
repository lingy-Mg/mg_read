import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/mg_read_app.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/library/application/library_overview_loader.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';
import 'package:mg_read/features/library/presentation/library_page.dart';
import 'package:mg_read/features/profile/presentation/profile_page.dart';

void main() {
  testWidgets(
    'shows loading then retains successful content on refresh failure',
    (WidgetTester tester) async {
      final _ControlledLibraryOverviewLoader loader =
          _ControlledLibraryOverviewLoader();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [libraryOverviewLoaderProvider.overrideWithValue(loader)],
          child: const MgReadApp(),
        ),
      );

      await tester.pump();
      expect(find.bySemanticsLabel('正在加载书架'), findsOneWidget);

      loader.completeNext(_overview('本地测试书籍'));
      await tester.pump();
      expect(find.text('本地测试书籍'), findsAtLeastNWidgets(1));

      final BuildContext context = tester.element(find.byType(LibraryPage));
      final ProviderContainer container = ProviderScope.containerOf(context);
      final Future<void> refresh = container
          .read(libraryPageControllerProvider.notifier)
          .refresh();
      await tester.pump();
      expect(find.bySemanticsLabel('正在刷新书架'), findsOneWidget);

      loader.completeNextError(AppError.fromCode(AppErrorCode.rateLimited));
      await refresh;
      await tester.pump();

      expect(find.text('本地测试书籍'), findsAtLeastNWidgets(1));
      expect(find.text('已保留上次成功加载的数据。'), findsOneWidget);
      expect(find.text('暂时无法完成请求'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    },
  );

  testWidgets('uses the generated typed reader route with a stable ID only', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: MgReadApp()));
    await tester.pumpAndSettle();

    final BuildContext context = tester.element(find.byType(LibraryPage));
    const ReaderRoute(bookId: 'book-local-42').go(context);
    await tester.pumpAndSettle();

    expect(find.text('阅读会话尚未就绪'), findsOneWidget);
    expect(
      find.text('此路由只保存稳定书籍 ID。后续由应用用例解析数据源和状态存储后再打开阅读器。'),
      findsOneWidget,
    );
  });

  testWidgets('ignores a pending library load after its route is disposed', (
    WidgetTester tester,
  ) async {
    final _ControlledLibraryOverviewLoader loader =
        _ControlledLibraryOverviewLoader();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [libraryOverviewLoaderProvider.overrideWithValue(loader)],
        child: const MgReadApp(),
      ),
    );
    await tester.pump();

    final BuildContext context = tester.element(find.byType(LibraryPage));
    const ReaderRoute(bookId: 'book-local-43').go(context);
    await tester.pumpAndSettle();

    loader.completeNext(_overview('stale result'));
    await tester.pump();

    expect(find.text('阅读会话尚未就绪'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('temporarily switches the app theme from the home top bar', (
    WidgetTester tester,
  ) async {
    final _ControlledLibraryOverviewLoader loader =
        _ControlledLibraryOverviewLoader();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [libraryOverviewLoaderProvider.overrideWithValue(loader)],
        child: const MgReadApp(themeMode: ThemeMode.light),
      ),
    );
    await tester.pump();
    loader.completeNext(_overview('主题切换测试书籍'));
    await tester.pumpAndSettle();

    final Finder toggle = find.byKey(const Key('theme-mode-toggle'));
    expect(toggle, findsOneWidget);
    expect(Theme.of(tester.element(toggle)).brightness, Brightness.light);
    expect(find.byTooltip('切换至深色模式'), findsOneWidget);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(toggle)).brightness, Brightness.dark);
    expect(find.byTooltip('切换至浅色模式'), findsOneWidget);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(toggle)).brightness, Brightness.light);
  });

  testWidgets('opens the profile route from the shared mobile navigation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: MgReadApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('app-nav-profile')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePage), findsOneWidget);
    expect(find.text('设置与管理'), findsOneWidget);

    final Finder profileToggle = find.byKey(const Key('theme-mode-toggle'));
    expect(
      Theme.of(tester.element(profileToggle)).brightness,
      Brightness.light,
    );
    await tester.tap(profileToggle);
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(profileToggle)).brightness, Brightness.dark);

    await tester.tap(find.byKey(const Key('app-nav-home')));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryPage), findsOneWidget);
  });
}

LibraryOverview _overview(String title) {
  return LibraryOverview(
    items: <LibraryItemSummary>[
      LibraryItemSummary(id: 'book-$title', title: title),
    ],
  );
}

final class _ControlledLibraryOverviewLoader implements LibraryOverviewLoader {
  final Queue<Completer<LibraryOverview>> _pending =
      Queue<Completer<LibraryOverview>>();

  @override
  Future<LibraryOverview> load() {
    final Completer<LibraryOverview> completer = Completer<LibraryOverview>();
    _pending.add(completer);
    return completer.future;
  }

  void completeNext(LibraryOverview overview) {
    _pending.removeFirst().complete(overview);
  }

  void completeNextError(Object error) {
    _pending.removeFirst().completeError(error);
  }
}
