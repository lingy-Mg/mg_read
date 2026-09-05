/// Content Library 支持的通知中心适配器。
///
/// 职责：将通知页面的窄端口映射到应用自有的有界通知仓储。
/// 注意：不缓存第二份列表，不在构造或启动时读取数据库。
library;

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/notifications/application/notification_center.dart';

final class ContentLibraryNotificationCenter implements NotificationCenter {
  const ContentLibraryNotificationCenter(this._library);

  final ContentLibrary _library;

  @override
  Future<List<LibraryNotification>> load() => _library.loadNotifications();

  @override
  Future<void> clear() => _library.clearNotifications();
}
