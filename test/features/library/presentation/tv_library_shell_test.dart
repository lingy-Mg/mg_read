import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/tv_library_data.dart';
import 'package:mg_read/features/library/presentation/widgets/tv_library_shell.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

void main() {
  test('secondary media uses reading and listening labels', () {
    for (final kind in [ContentKind.novel, ContentKind.manga, ContentKind.audio]) {
      final book = LibraryBookListItemViewData(
        id: 'item',
        title: '内容',
        contentKind: kind,
        coverVariant: LibraryCoverVariant.ocean,
        status: LibraryBookStatus.local,
      );
      final verb = kind == ContentKind.audio ? '收听' : '阅读';
      expect(TvLibraryEntry(book, null).actionLabel, verb);
      expect(TvLibraryEntry(book, null).progressLabel, '尚未$verb');
      expect(TvLibraryEntry(book, LibraryItemSummary(id: 'item', title: '内容', lastReadAtUtc: DateTime.utc(2026))).progressLabel, '上次$verb');
    }
  });

  testWidgets('remote directions traverse a long TV shelf without jumping back to the hero', (tester) async {
    final books = List.generate(
      100,
      (i) => LibraryBookListItemViewData(
        id: 'remote-$i',
        title: '影片 $i',
        contentKind: ContentKind.video,
        coverVariant: LibraryCoverVariant.ocean,
        status: LibraryBookStatus.local,
      ),
    );
    await _mount(
      tester,
      data: TvLibraryData(LibraryHomeViewData(isPresentationFixture: true, continueReading: null, books: books), const []),
    );
    final focus = tester.widget<Focus>(find.descendant(of: find.byKey(const Key('tv-card-remote-0')), matching: find.byType(Focus)).first);
    focus.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    for (var i = 0; i < 30; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    final key = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvFocusable>()?.key;
    expect(key, isA<ValueKey<String>>());
    expect(int.tryParse((key! as ValueKey<String>).value.split('-').last) ?? -1, greaterThanOrEqualTo(30));
  });

  testWidgets('TV more menu fits a short display with large text', (tester) async {
    await _mount(
      tester,
      size: const Size(640, 360),
      textScale: 1.6,
      callbacks: LibraryHomeCallbacks(onRefreshBook: (_) async {}, onDeleteBook: (_) async {}),
    );
    await tester.tap(find.byKey(const Key('tv-nav-movies')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('tv-card-movie')), 180, scrollable: find.byType(Scrollable).first);
    final focus = tester.widget<Focus>(find.descendant(of: find.byKey(const Key('tv-card-movie')), matching: find.byType(Focus)).first);
    focus.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/tv_library_menu_large_text.png'));
    // Reach Cancel by remote; the dialog must scroll with focus.
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(focus.focusNode!.hasFocus, isTrue);
  });

  setUpAll(() async {
    final font = FontLoader('packages/novel_reader_ui/MiSans')
      ..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'));
    final icons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([font.load(), icons.load()]);
  });

  testWidgets('TV home visual reference', (tester) async {
    await _mount(tester, size: const Size(1920, 1080));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/tv_library_home_dark.png'));
  });
  test('resume ignores newer novels, filters use only explicit video classification', () {
    final data = _data();
    expect(data.resume?.book.id, 'series');
    expect(data.filtered(TvLibraryFilter.all).map((e) => e.book.id), ['movie', 'series', 'unknown']);
    expect(data.filtered(TvLibraryFilter.movies).map((e) => e.book.id), ['movie']);
    expect(data.filtered(TvLibraryFilter.series).map((e) => e.book.id), ['series']);
    expect(data.filtered(TvLibraryFilter.reading).map((e) => e.book.id), ['novel']);
  });

  testWidgets('remote centre resumes video and repeated activation is serialized', (tester) async {
    final pending = Completer<void>();
    final played = <String>[];
    await _mount(
      tester,
      onPlay: (book) {
        played.add(book.id);
        return pending.future;
      },
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(played, ['series']);
    pending.complete();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvLibraryShell>(), isNotNull);
  });

  testWidgets('movie filter, remote menu, cancel and focus restoration keep shelf reachable', (tester) async {
    final removed = <String>[];
    await _mount(
      tester,
      callbacks: LibraryHomeCallbacks(
        onDeleteBook: (book) async {
          removed.add(book.id);
        },
      ),
    );
    await tester.tap(find.byKey(const Key('tv-nav-movies')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tv-card-series')), findsNothing);
    expect(find.byKey(const Key('tv-card-movie')), findsOneWidget);
    final cardFocus = tester.widget<Focus>(find.descendant(of: find.byKey(const Key('tv-card-movie')), matching: find.byType(Focus)).first);
    cardFocus.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('移除收藏'));
    await tester.pumpAndSettle();
    expect(find.text('移除收藏？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(removed, isEmpty);
    expect(cardFocus.focusNode!.hasFocus, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tv-card-series')), findsOneWidget);
  });

  testWidgets('empty television library does not promote books as video', (tester) async {
    await _mount(tester, data: TvLibraryData(LibraryHomeViewData.empty(), const []));
    expect(find.text('暂无对应的影视收藏'), findsOneWidget);
    expect(find.byKey(const Key('tv-continue')), findsNothing);
    expect(find.byKey(const Key('tv-nav-mode')), findsOneWidget);
  });

  testWidgets('large TV shelves build visible cards lazily and reach later videos', (tester) async {
    final books = List.generate(
      100,
      (i) => LibraryBookListItemViewData(
        id: 'video-$i',
        title: '影片 $i',
        contentKind: ContentKind.video,
        coverVariant: LibraryCoverVariant.ocean,
        status: LibraryBookStatus.local,
      ),
    );
    await _mount(
      tester,
      data: TvLibraryData(LibraryHomeViewData(isPresentationFixture: true, continueReading: null, books: books), const []),
    );
    expect(find.byKey(const Key('tv-card-video-50')), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const Key('tv-card-video-50')),
      500,
      maxScrolls: 30,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('tv-card-video-50')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(1280, 720), const Size(1920, 1080), const Size(640, 480)]) {
    testWidgets('TV library fits $size without overflow', (tester) async {
      await _mount(tester, size: size);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.byKey(const Key('tv-nav-reading')), 250, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tv-nav-reading')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _mount(
  WidgetTester tester, {
  Size size = const Size(1280, 720),
  TvLibraryData? data,
  LibraryHomeCallbacks callbacks = const LibraryHomeCallbacks(),
  Future<void> Function(LibraryBookListItemViewData)? onPlay,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appTvTheme(AppTheme.dark()),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: TvModeScope(
          enabled: true,
          onChanged: (_) {},
          child: TvRemoteShortcuts(
            child: TvLibraryShell(
              data: data ?? _data(),
              callbacks: callbacks,
              onPlay: onPlay ?? (_) async {},
              onDetail: (_) async {},
              onRefresh: () async {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

TvLibraryData _data() {
  final items = [
    LibraryItemSummary(
      id: 'movie',
      title: '星际归途',
      contentKind: ContentKind.video,
      categories: ['电影'],
      lastReadAtUtc: DateTime.utc(2026, 10, 28),
    ),
    LibraryItemSummary(
      id: 'series',
      title: '雾港来信',
      contentKind: ContentKind.video,
      categories: ['电视剧'],
      lastReadAtUtc: DateTime.utc(2026, 10, 29),
    ),
    const LibraryItemSummary(id: 'unknown', title: '未分类影片', contentKind: ContentKind.video, chapterCount: 1),
    LibraryItemSummary(id: 'novel', title: '测试小说', lastReadAtUtc: DateTime.utc(2026, 10, 30)),
  ];
  return TvLibraryData(
    LibraryHomeViewData(
      isPresentationFixture: true,
      continueReading: null,
      books: [
        for (final item in items)
          LibraryBookListItemViewData(
            id: item.id,
            title: item.title,
            contentKind: item.contentKind,
            coverVariant: LibraryCoverVariant.ocean,
            status: LibraryBookStatus.local,
          ),
      ],
    ),
    items,
  );
}
