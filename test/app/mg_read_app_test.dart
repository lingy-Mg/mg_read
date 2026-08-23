import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/mg_read_app.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/library/application/library_overview_loader.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';
import 'package:mg_read/features/library/presentation/library_page.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list.dart';
import 'package:mg_read/features/discovery/presentation/discovery_destination_page.dart';
import 'package:mg_read/features/discovery/presentation/search_page.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/profile/presentation/profile_page.dart';
import 'package:mg_read/features/reader/application/library_reader_launcher.dart';
import 'package:mg_read/features/reader/application/reader_launch_failure.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';

import '../core/diagnostics/diagnostics_testkit.dart';
import 'mg_read_app_test_support.dart';

void main() {
  testWidgets(
    'shows loading then retains successful content on refresh failure',
    (WidgetTester tester) async {
      final settings = await createTestAppSettings();
      addTearDown(settings.close);
      final _ControlledLibraryOverviewLoader loader =
          _ControlledLibraryOverviewLoader();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsProvider.overrideWithValue(settings),
            libraryOverviewLoaderProvider.overrideWithValue(loader),
            pluginRuntimeGatewayProvider.overrideWithValue(
              const TestReadyPluginRuntimeGateway(),
            ),
          ],
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
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(settings),
          pluginRuntimeGatewayProvider.overrideWithValue(
            const TestReadyPluginRuntimeGateway(),
          ),
          libraryReaderLauncherProvider.overrideWithValue(
            const _FailingReaderLauncher(),
          ),
        ],
        child: const MgReadApp(),
      ),
    );
    await tester.pumpAndSettle();

    final BuildContext context = tester.element(find.byType(LibraryPage));
    const ReaderRoute(bookId: 'book-local-42').go(context);
    await tester.pumpAndSettle();

    expect(find.text('暂时无法开始阅读'), findsOneWidget);
    expect(find.text('无法从书源获取这本书的详情。'), findsOneWidget);
    expect(
      find.text('诊断代码：reader_launch_source_detail_timeout'),
      findsOneWidget,
    );
  });

  testWidgets('opens a persisted shelf item directly in the reader', (
    WidgetTester tester,
  ) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(settings),
          libraryOverviewLoaderProvider.overrideWithValue(
            const _SingleBookOverviewLoader(),
          ),
          libraryReaderLauncherProvider.overrideWithValue(
            const _FailingReaderLauncher(),
          ),
          pluginRuntimeGatewayProvider.overrideWithValue(
            const TestReadyPluginRuntimeGateway(),
          ),
        ],
        child: const MgReadApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(LibraryBookListItem).first);
    await tester.pumpAndSettle();

    expect(find.text('暂时无法开始阅读'), findsOneWidget);
    expect(
      find.text('诊断代码：reader_launch_source_detail_timeout'),
      findsOneWidget,
    );
  });

  testWidgets('route and reader diagnostics never persist route parameters', (
    WidgetTester tester,
  ) async {
    const secretBookId = 'book-Bearer-ROUTE-SECRET-CANARY';
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    await tester.pumpWidget(
      testMgReadApp(settings, diagnostics: diagnostics.manager),
    );
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(LibraryPage));
    const ReaderRoute(bookId: secretBookId).go(context);
    await tester.pumpAndSettle();

    expect(
      diagnostics.sink.events
          .where((event) => event.eventName == 'app.route.changed')
          .map((event) => event.attributes.values['toRoute']),
      contains(DiagnosticStringValue('reader')),
    );
    expect(
      diagnostics.sink.events.where(
        (event) =>
            event.eventName == 'reader.launch.stage.start' &&
            event.attributes.values['stage'] ==
                DiagnosticStringValue('requestBuild'),
      ),
      isNotEmpty,
    );
    final encoded = jsonEncode(
      diagnostics.sink.events
          .map(const DiagnosticEventCodec().encode)
          .toList(growable: false),
    );
    expect(encoded, isNot(contains(secretBookId)));
  });

  testWidgets('ignores a pending library load after its route is disposed', (
    WidgetTester tester,
  ) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    final _ControlledLibraryOverviewLoader loader =
        _ControlledLibraryOverviewLoader();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(settings),
          libraryOverviewLoaderProvider.overrideWithValue(loader),
          pluginRuntimeGatewayProvider.overrideWithValue(
            const TestReadyPluginRuntimeGateway(),
          ),
        ],
        child: const MgReadApp(),
      ),
    );
    await tester.pump();

    final BuildContext context = tester.element(find.byType(LibraryPage));
    const ReaderRoute(bookId: 'book-local-43').go(context);
    await tester.pumpAndSettle();

    loader.completeNext(_overview('stale result'));
    await tester.pump();

    expect(find.text('暂时无法开始阅读'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('temporarily keeps the app in light-only mode', (
    WidgetTester tester,
  ) async {
    final settings = await createTestAppSettings(themeMode: 'light');
    addTearDown(settings.close);
    final _ControlledLibraryOverviewLoader loader =
        _ControlledLibraryOverviewLoader();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(settings),
          libraryOverviewLoaderProvider.overrideWithValue(loader),
          pluginRuntimeGatewayProvider.overrideWithValue(
            const TestReadyPluginRuntimeGateway(),
          ),
        ],
        child: const MgReadApp(),
      ),
    );
    await tester.pump();
    loader.completeNext(_overview('主题切换测试书籍'));
    await tester.pumpAndSettle();

    _expectBrightnessForCurrentPage(tester, Brightness.light);
    expect(find.byKey(const Key('theme-mode-toggle')), findsNothing);
    expect(settings.get(AppSettingKeys.themeMode), 'light');
  });

  testWidgets('opens the profile route from the shared mobile navigation', (
    WidgetTester tester,
  ) async {
    final settings = await createTestAppSettings(themeMode: 'light');
    addTearDown(settings.close);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('app-nav-profile')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePage), findsOneWidget);
    expect(find.text('设置与管理'), findsOneWidget);

    _expectBrightnessForCurrentPage(tester, Brightness.light);
    expect(find.byKey(const Key('theme-mode-toggle')), findsNothing);

    await tester.tap(find.byKey(const Key('app-nav-home')));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryPage), findsOneWidget);
  });

  testWidgets('keeps light mode when the operating system prefers dark mode', (
    WidgetTester tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final settings = await createTestAppSettings();
    addTearDown(settings.close);

    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();

    _expectBrightnessForCurrentPage(tester, Brightness.light);
    expect(find.byKey(const Key('theme-mode-toggle')), findsNothing);

    await tester.tap(find.byKey(const Key('app-nav-search')));
    await tester.pumpAndSettle();
    expect(find.byType(SearchPage), findsOneWidget);
    _expectBrightnessForCurrentPage(tester, Brightness.light);

    await tester.tap(find.byKey(const Key('app-nav-discover')));
    await tester.pumpAndSettle();
    expect(find.byType(DiscoveryDestinationPage), findsOneWidget);
    _expectBrightnessForCurrentPage(tester, Brightness.light);

    await tester.tap(find.byKey(const Key('app-nav-profile')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePage), findsOneWidget);
    _expectBrightnessForCurrentPage(tester, Brightness.light);
  });
}

final class _FailingReaderLauncher implements LibraryReaderLauncher {
  const _FailingReaderLauncher();

  @override
  Future<ReaderLaunchRequest> launch(
    String libraryItemId, {
    ReaderObserver? observer,
  }) => Future<ReaderLaunchRequest>.error(
    ReaderLaunchFailure(
      reason: ReaderLaunchFailureReason.sourceDetail,
      error: AppError.fromCode(AppErrorCode.timeout),
    ),
  );
}

final class _SingleBookOverviewLoader implements LibraryOverviewLoader {
  const _SingleBookOverviewLoader();

  @override
  Future<LibraryOverview> load() async => _overview('书架详情测试');
}

void _expectBrightnessForCurrentPage(
  WidgetTester tester,
  Brightness brightness,
) {
  final Finder page = find.byWidgetPredicate(
    (Widget widget) =>
        widget is LibraryPage ||
        widget is SearchPage ||
        widget is DiscoveryDestinationPage ||
        widget is ProfilePage,
  );
  expect(page, findsOneWidget);
  expect(Theme.of(tester.element(page)).brightness, brightness);
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
