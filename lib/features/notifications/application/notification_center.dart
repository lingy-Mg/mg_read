/// 通知中心的应用层读取与清理边界。
///
/// 职责：
/// - 只在通知页主动请求时加载有界本地记录。
/// - 隔离页面与 Content Library 的持久化实现。
///
/// 注意：
/// - 不建立常驻监听、轮询或后台 isolate。
/// - 记录生产由业务成功提交后异步触发，通知失败不影响主业务。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/content_library/content_library.dart';

abstract interface class NotificationCenter {
  Future<List<LibraryNotification>> load();

  Future<void> clear();
}

final notificationCenterProvider = Provider<NotificationCenter>((Ref ref) => const EmptyNotificationCenter());

final class EmptyNotificationCenter implements NotificationCenter {
  const EmptyNotificationCenter();

  @override
  Future<List<LibraryNotification>> load() async => const <LibraryNotification>[];

  @override
  Future<void> clear() async {}
}
