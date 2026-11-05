import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';

void main() {
  test('counts only chapters after a known position without inventing missing progress', () {
    final cases = <({int? count, int? position, double? progress, int unread})>[
      (count: 120, position: null, progress: null, unread: 120),
      (count: 120, position: 0, progress: 0.01, unread: 119),
      (count: 120, position: 119, progress: 1, unread: 0),
      (count: 120, position: 130, progress: 1, unread: 0),
      (count: 120, position: -1, progress: null, unread: 0),
      (count: 120, position: null, progress: 0.4, unread: 0),
      (count: null, position: 2, progress: 0.4, unread: 0),
      (count: 0, position: null, progress: null, unread: 0),
    ];
    for (final kind in ContentKind.values) {
      for (final sample in cases) {
        final book = LibraryItemSummary(
          id: 'count-test',
          title: '数量测试',
          contentKind: kind,
          chapterCount: sample.count,
          readingChapterIndex: sample.position,
          readingProgress: sample.progress,
        );
        final data = LibraryHomeViewData.fromLocalOverview(LibraryOverview(items: [book]));
        expect(
          data.books.single.unreadChapterCount,
          kind == ContentKind.novel || kind == ContentKind.manga ? sample.unread : 0,
          reason: '$kind / $sample',
        );
        expect(
          LibraryHomeViewData.fromLocalOverview(LibraryOverview(items: [book]), showUnreadBadges: false).books.single.unreadChapterCount,
          0,
        );
      }
    }
  });

  test('does not report a previously read item with an unknown position as entirely unread', () {
    final data = LibraryHomeViewData.fromLocalOverview(
      LibraryOverview(
        items: [LibraryItemSummary(id: 'unknown-position', title: '进度待恢复', chapterCount: 120, lastReadAtUtc: DateTime.utc(2026, 11, 5))],
      ),
    );
    expect(data.books.single.unreadChapterCount, 0);
  });

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
    expect(data.books.single.contentKind, ContentKind.audio);
    expect(data.books.single.coverOrientation, CoverOrientation.square);
  });
}
