import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';

void main() {
  test('keeps the current book author and description in the home projection', () {
    final data = LibraryHomeViewData.fromLocalOverview(
      LibraryOverview(
        items: <LibraryItemSummary>[
          LibraryItemSummary(
            id: 'current-book',
            title: '测试书名',
            author: '测试作者',
            description: '测试简介',
            readingProgress: 0.4,
            readingChapterIndex: 2,
            lastReadAtUtc: DateTime.utc(2026, 8, 30),
          ),
        ],
      ),
    );

    expect(data.continueReading?.title, '测试书名');
    expect(data.continueReading?.author, '测试作者');
    expect(data.continueReading?.description, '测试简介');
  });

  test('projects type-aware continuation semantics across all content kinds', () {
    final expectations = <ContentKind, ({String action, String chapter, String progress})>{
      ContentKind.novel: (action: '继续阅读', chapter: '第3章', progress: '阅读进度'),
      ContentKind.manga: (action: '继续阅读', chapter: '第3话', progress: '阅读进度'),
      ContentKind.audio: (action: '继续收听', chapter: '上次收听', progress: '播放进度'),
      ContentKind.video: (action: '继续观看', chapter: '上次观看', progress: '播放进度'),
    };

    for (final entry in expectations.entries) {
      final data = LibraryHomeViewData.fromLocalOverview(
        LibraryOverview(
          items: <LibraryItemSummary>[
            LibraryItemSummary(
              id: 'current-${entry.key.code}',
              title: '测试条目',
              contentKind: entry.key,
              readingProgress: entry.key == ContentKind.novel || entry.key == ContentKind.manga ? 0.4 : null,
              readingChapterIndex: 2,
              lastReadAtUtc: DateTime.utc(2026, 8, 30),
            ),
          ],
        ),
      );
      final current = data.continueReading!;

      expect(current.contentKind, entry.key);
      expect(current.actionLabel, entry.value.action);
      expect(current.chapter, entry.value.chapter);
      expect(current.progressLabel, entry.value.progress);
      expect(current.hasDeterminateProgress, entry.key == ContentKind.novel || entry.key == ContentKind.manga);
    }
  });

  test('projects the persisted cover blur state onto the current book and shelf rows', () {
    final data = LibraryHomeViewData.fromLocalOverview(
      LibraryOverview(
        items: <LibraryItemSummary>[
          LibraryItemSummary(id: 'blurred-book', title: '隐私书籍', readingProgress: 0.2, lastReadAtUtc: DateTime.utc(2026, 8, 30)),
          LibraryItemSummary(id: 'normal-book', title: '普通书籍'),
        ],
      ),
      blurredBookIds: const <String>{'blurred-book'},
    );

    expect(data.continueReading?.isCoverBlurred, isTrue);
    expect(data.books.first.isCoverBlurred, isTrue);
    expect(data.books.last.isCoverBlurred, isFalse);
  });

  test('keeps source-declared cover composition in every home projection', () {
    final data = LibraryHomeViewData.fromLocalOverview(
      LibraryOverview(
        items: <LibraryItemSummary>[
          LibraryItemSummary(
            id: 'square-audio',
            title: '方形音频',
            contentKind: ContentKind.audio,
            coverOrientation: CoverOrientation.square,
            lastReadAtUtc: DateTime.utc(2026, 9, 11),
          ),
        ],
      ),
    );

    expect(data.continueReading?.coverOrientation, CoverOrientation.square);
    expect(data.books.single.coverOrientation, CoverOrientation.square);
  });
}
