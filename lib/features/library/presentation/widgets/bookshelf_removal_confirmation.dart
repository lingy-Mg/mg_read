/// 书架移除确认对话框。
///
/// 职责：
/// - 为首页、隐私书架和发现详情提供一致的危险操作确认。
///
/// 注意：
/// - 只负责收集用户确认，不执行持久化或修改页面状态。
library;

import 'package:flutter/material.dart';

Future<bool> showBookshelfRemovalConfirmation(BuildContext context, {required String title}) async {
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const Key('bookshelf-removal-confirmation'),
          title: const Text('删除书籍'),
          content: Text('确定要从书架移除《${title.trim()}》吗？'),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('删除')),
          ],
        ),
      ) ??
      false;
}
