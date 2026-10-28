import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';
import 'package:mg_read/features/library/presentation/widgets/library_continue_reading_card.dart';

void main() {
  testWidgets('renders an immersive surface with a flat cover on the right', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: LibraryContinueReadingCard(data: LibraryHomeFixtures.preview.continueReading!, onContinueReading: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    final Rect surface = tester.getRect(find.byKey(const Key('continue-reading-surface')));
    final Rect action = tester.getRect(find.byKey(const Key('continue-reading-cta')));
    final Finder flatCover = find.byKey(const Key('continue-reading-flat-cover'));
    final Rect cover = tester.getRect(flatCover);
    final Rect title = tester.getRect(find.text('诡秘之主'));
    final Element surfaceElement = tester.element(find.byKey(const Key('continue-reading-surface')));
    final List<Widget> localCoverAncestors = <Widget>[];
    tester.element(flatCover).visitAncestorElements((Element element) {
      if (identical(element, surfaceElement)) return false;
      localCoverAncestors.add(element.widget);
      return true;
    });

    expect(find.byType(LibraryBookCover), findsNWidgets(2));
    final LibraryBookCover foregroundCover = tester.widget<LibraryBookCover>(flatCover);
    expect(foregroundCover.fit, BoxFit.contain);
    expect(foregroundCover.showLetterboxBackground, isFalse);
    expect(find.descendant(of: flatCover, matching: find.byKey(const Key('book-cover-image-clip'))), findsOneWidget);
    expect(localCoverAncestors.whereType<Transform>(), isEmpty);
    expect(localCoverAncestors.whereType<RotatedBox>(), isEmpty);
    expect(surface.contains(cover.topLeft), isTrue);
    expect(surface.contains(cover.bottomRight), isTrue);
    expect(title.right, lessThan(cover.left));
    expect(action.right, lessThan(cover.left));
  });

  testWidgets('places book metadata above the home reading action', (WidgetTester tester) async {
    const data = LibraryContinueReadingViewData(
      bookId: 'metadata-book',
      title: '书名',
      author: '作者名',
      description: '这是首页继续阅读区域使用的作品简介。',
      chapter: '第1章',
      progress: 0.5,
      lastReadLabel: '刚刚',
      coverVariant: LibraryCoverVariant.dusk,
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: LibraryContinueReadingCard(data: data, showBackdrop: false, onContinueReading: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect title = tester.getRect(find.byKey(const Key('continue-reading-title')));
    final Rect author = tester.getRect(find.byKey(const Key('continue-reading-author')));
    final Rect description = tester.getRect(find.byKey(const Key('continue-reading-description')));
    final Rect action = tester.getRect(find.byKey(const Key('continue-reading-cta')));
    final Text authorText = tester.widget<Text>(find.byKey(const Key('continue-reading-author')));
    final Text descriptionText = tester.widget<Text>(find.byKey(const Key('continue-reading-description')));
    final Color onSurface = Theme.of(tester.element(find.byKey(const Key('continue-reading-title')))).colorScheme.onSurface;

    expect(find.text('作者 · 作者名'), findsOneWidget);
    expect(find.text('这是首页继续阅读区域使用的作品简介。'), findsOneWidget);
    expect(title.bottom, lessThanOrEqualTo(author.top));
    expect(author.bottom, lessThanOrEqualTo(description.top));
    expect(description.bottom, lessThanOrEqualTo(action.top));
    expect(authorText.style?.color, onSurface);
    expect(descriptionText.style?.color, onSurface);
    expect(descriptionText.maxLines, 1);
    expect(find.byKey(const Key('continue-reading-position')), findsOneWidget);
    expect(descriptionText.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses playback language and omits invented progress for audio and video', (WidgetTester tester) async {
    for (final kind in <ContentKind>[ContentKind.audio, ContentKind.video]) {
      final actionLabel = kind == ContentKind.audio ? '继续收听' : '继续观看';
      final data = LibraryContinueReadingViewData(
        bookId: 'media-${kind.code}',
        contentKind: kind,
        title: '媒体条目',
        chapter: '上次播放',
        progress: 0,
        hasDeterminateProgress: false,
        lastReadLabel: '刚刚',
        coverVariant: LibraryCoverVariant.dusk,
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: LibraryContinueReadingCard(data: data, showBackdrop: false, onContinueReading: () {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(actionLabel), findsOneWidget);
      expect(find.byKey(const Key('continue-reading-cta-progress')), findsNothing);
      expect(tester.getSemantics(find.byKey(const Key('continue-reading-cta'))).label, contains(actionLabel));
    }
  });

  testWidgets('keeps the action bounded at a narrow width with enlarged text', (WidgetTester tester) async {
    const LibraryContinueReadingViewData data = LibraryContinueReadingViewData(
      bookId: 'narrow-action',
      title: '窄屏继续阅读条目',
      chapter: '第1章',
      progress: 0.42,
      lastReadLabel: '刚刚',
      coverVariant: LibraryCoverVariant.dusk,
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: Scaffold(
              body: SizedBox(
                width: 260,
                child: LibraryContinueReadingCard(data: data, onContinueReading: _noop),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect action = tester.getRect(find.byKey(const Key('continue-reading-cta')));
    final Text actionText = tester.widget<Text>(
      find.descendant(of: find.byKey(const Key('continue-reading-cta')), matching: find.text(data.actionLabel)),
    );
    final SemanticsNode semantics = tester.getSemantics(find.byKey(const Key('continue-reading-cta')));

    expect(tester.takeException(), isNull);
    expect(action.size, const Size(136, AppSpacing.minimumTouchTarget));
    expect(actionText.maxLines, 1);
    expect(actionText.overflow, TextOverflow.ellipsis);
    expect(semantics.label, contains(data.actionLabel));
  });
}

void _noop() {}
