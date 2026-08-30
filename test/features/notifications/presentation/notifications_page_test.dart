/// 通知页面的有界列表与本地清理测试。
///
/// 职责：验证真实操作记录、空态、清空确认和错误隔离。
/// 注意：使用内存端口，不访问用户数据库或依赖系统时间格式之外的精确文案。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/notifications/application/notification_center.dart';
import 'package:mg_read/features/notifications/presentation/notifications_page.dart';

void main() {
  testWidgets('renders shelf operation notifications newest first', (WidgetTester tester) async {
    final center = _FakeNotificationCenter(<LibraryNotification>[
      LibraryNotification(id: 'removed', kind: LibraryNotificationKind.bookshelfRemoved, title: '旧书', occurredAt: DateTime.now()),
      LibraryNotification(
        id: 'added',
        kind: LibraryNotificationKind.bookshelfAdded,
        title: '新书',
        occurredAt: DateTime.now().subtract(const Duration(minutes: 2)),
      ),
    ]);
    await tester.pumpWidget(_host(center));
    await tester.pumpAndSettle();

    expect(find.text('通知'), findsOneWidget);
    expect(find.text('操作记录'), findsOneWidget);
    expect(find.text('已移出书架'), findsOneWidget);
    expect(find.text('《旧书》已从书架移除。'), findsOneWidget);
    expect(find.text('已加入书架'), findsOneWidget);
    expect(find.text('《新书》已加入书架。'), findsOneWidget);
    expect(find.byKey(const Key('notifications-list')), findsOneWidget);
  });

  testWidgets('clears only after explicit confirmation', (WidgetTester tester) async {
    final center = _FakeNotificationCenter(<LibraryNotification>[
      LibraryNotification(id: 'added', kind: LibraryNotificationKind.bookshelfAdded, title: '待清理', occurredAt: DateTime.now()),
    ]);
    await tester.pumpWidget(_host(center));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('notifications-clear')));
    await tester.pumpAndSettle();
    expect(find.text('这只会删除本机通知记录，不会修改书架内容。'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();

    expect(center.clearCount, 1);
    expect(find.byKey(const Key('notifications-empty')), findsOneWidget);
    expect(find.text('暂无通知'), findsOneWidget);
  });
}

Widget _host(NotificationCenter center) => MaterialApp(
  theme: AppTheme.light(),
  home: NotificationsPage(center: center, onBackRequested: () {}),
);

final class _FakeNotificationCenter implements NotificationCenter {
  _FakeNotificationCenter(this.entries);

  List<LibraryNotification> entries;
  int clearCount = 0;

  @override
  Future<List<LibraryNotification>> load() async => List<LibraryNotification>.unmodifiable(entries);

  @override
  Future<void> clear() async {
    clearCount++;
    entries = <LibraryNotification>[];
  }
}
