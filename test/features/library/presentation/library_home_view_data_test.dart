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
}
