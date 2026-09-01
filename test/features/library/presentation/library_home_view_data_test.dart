import 'package:flutter_test/flutter_test.dart';
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

  test('projects media playback as current without inventing a full-book fraction', () {
    final data = LibraryHomeViewData.fromLocalOverview(
      LibraryOverview(
        items: <LibraryItemSummary>[LibraryItemSummary(id: 'current-video', title: '测试视频', lastReadAtUtc: DateTime.utc(2026, 8, 30))],
      ),
    );

    expect(data.continueReading?.title, '测试视频');
    expect(data.continueReading?.progress, 0);
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
}
