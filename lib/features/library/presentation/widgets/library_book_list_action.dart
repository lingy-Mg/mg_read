/// 书架书籍列表操作。
///
/// 职责：
/// - 描述由书架页面提供的单一书籍操作。
/// - 让菜单、侧滑面板和底部详情弹层共享同一操作身份。
///
/// 注意：
/// - 此类型只描述展示动作，不执行持久化或导航。
///
/// TODO:
/// - 无。
library;

import 'package:flutter/foundation.dart';

/// One explicit book-list action supplied by the owning library surface.
@immutable
final class LibraryBookListAction {
  const LibraryBookListAction({required this.id, required this.label}) : assert(id != ''), assert(label != '');

  final String id;
  final String label;
}
