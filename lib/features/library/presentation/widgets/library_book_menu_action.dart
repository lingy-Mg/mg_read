/// 书籍菜单的展示映射。
///
/// 职责：为列表与卡片提供一致的图标、分组和删除强调。
/// 注意：仅按已有动作身份生成展示数据；动态文案与业务回调仍由宿主拥有，无 IO。
library;

import 'package:flutter/material.dart';

import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_anchored_menu.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list_action.dart';

extension LibraryBookMenuAction on LibraryBookListAction {
  LibraryAnchoredMenuAction toMenuAction(LibraryBookListItemViewData book, {required VoidCallback onSelected, Key? key}) {
    return LibraryAnchoredMenuAction(
      key: key,
      label: labelFor(book),
      icon: switch (id) {
        'detail' => Icons.info_outline_rounded,
        'refresh' => Icons.refresh_rounded,
        'set-private' => Icons.lock_outline_rounded,
        'restore-normal' => Icons.lock_open_rounded,
        'toggle-cover-blur' => Icons.blur_on_rounded,
        'delete' => Icons.delete_outline_rounded,
        _ => Icons.more_horiz_rounded,
      },
      isDestructive: id == 'delete',
      startsSection: id == 'delete',
      onSelected: onSelected,
    );
  }
}
