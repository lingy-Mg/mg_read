import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list.dart';

void main() {
  testWidgets(
    'keeps recent updates, shelf, and reading history on the shared row grid',
    (WidgetTester tester) async {
      final Map<String, LibraryBookListPresentation> presentations =
          <String, LibraryBookListPresentation>{
            'updates': LibraryBookListPresentation.recentUpdates,
            'shelf': LibraryBookListPresentation.shelf,
            'history': LibraryBookListPresentation.readingHistory,
          };

      for (final MapEntry<String, LibraryBookListPresentation> entry
          in presentations.entries) {
        await _setViewport(tester, const Size(390, 300));
        await tester.pumpWidget(_host(presentation: entry.value));
        await tester.pumpAndSettle();

        final Finder row = find.byType(LibraryBookListItem);
        final Finder cover = find.byType(LibraryBookCover);
        final Finder tag = find.byType(LibraryMetadataTag);
        final Rect rowRect = tester.getRect(row);
        final Rect coverRect = tester.getRect(cover);
        final Rect tagRect = tester.getRect(tag);

        expect(find.byType(LibraryBookList), findsOneWidget);
        expect(coverRect.width, AppSpacing.listCoverWidth);
        expect(coverRect.height, AppSpacing.listCoverHeight);
        expect(
          rowRect.height,
          closeTo(
            coverRect.height + AppSpacing.bookListVerticalPadding * 2,
            0.1,
          ),
        );
        expect((coverRect.bottom - tagRect.bottom).abs(), lessThanOrEqualTo(4));

        final Finder attentionIndicator = find.byWidgetPredicate(
          (Widget widget) =>
              widget is Semantics && widget.properties.label == '有更新',
        );
        expect(
          attentionIndicator,
          entry.key == 'updates' ? findsOneWidget : findsNothing,
        );
      }
    },
  );

  testWidgets('supports explicit compact-row visibility customization', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 300));
    await tester.pumpWidget(
      _host(
        presentation: const LibraryBookListPresentation(
          showActivityLabel: false,
          showOverflowAction: false,
          showAttentionIndicator: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('上次阅读 · 1小时前'), findsNothing);
    expect(find.byTooltip('书籍更多操作'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is Semantics && widget.properties.label == '有更新',
      ),
      findsOneWidget,
    );
  });

  testWidgets('forwards book and overflow intents with the original item', (
    WidgetTester tester,
  ) async {
    LibraryBookListItemViewData? opened;
    LibraryBookListItemViewData? openedMore;
    await _setViewport(tester, const Size(390, 300));
    await tester.pumpWidget(
      _host(
        presentation: LibraryBookListPresentation.recentUpdates,
        onOpenBook: (LibraryBookListItemViewData item) {
          opened = item;
        },
        onBookMore: (LibraryBookListItemViewData item) {
          openedMore = item;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('测试书籍').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('书籍更多操作'));
    await tester.pumpAndSettle();

    expect(opened, same(_book));
    expect(openedMore, same(_book));
  });
}

final LibraryBookListItemViewData _book = LibraryBookListItemViewData(
  id: 'shared-book-list-test',
  title: '测试书籍',
  subtitle: '第1268章 测试章节',
  activityLabel: '上次阅读 · 1小时前',
  coverVariant: LibraryCoverVariant.dusk,
  status: LibraryBookStatus.ongoing,
  hasAttentionIndicator: true,
  tags: const <LibraryMetadataTagViewData>[
    LibraryMetadataTagViewData(label: '测试书源', tone: LibraryMetadataTone.accent),
  ],
);

Widget _host({
  required LibraryBookListPresentation presentation,
  ValueChanged<LibraryBookListItemViewData>? onOpenBook,
  ValueChanged<LibraryBookListItemViewData>? onBookMore,
}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.compactPagePadding,
        ),
        child: LibraryBookList(
          books: <LibraryBookListItemViewData>[_book],
          presentation: presentation,
          onOpenBook: onOpenBook ?? (_) {},
          onBookMore: onBookMore ?? (_) {},
        ),
      ),
    ),
  );
}

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump();
}
