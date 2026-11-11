/// 书架阅读启动失败提示。
/// 提示由当前 ScaffoldMessenger 持有，五秒后自动消失，也可关闭或重试；
/// 连续失败替换待显示提示，避免错误队列持续占据页面。组件不持有启动任务或 IO。
/// 详细错误通过显式入口展示，用户可选择或复制后反馈。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mg_read/shared/presentation/widgets/app_operation_error_dialog.dart';

void showLibraryReaderLaunchError(BuildContext context, {required String message, Object? error, required VoidCallback onRetry}) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(message, maxLines: 4, overflow: TextOverflow.ellipsis),
            TextButton(
              onPressed: () =>
                  unawaited(showAppOperationErrorDialog(context, operation: '打开书籍', error: error ?? message, guidance: message)),
              child: const Text('错误详情'),
            ),
          ],
        ),
        duration: const Duration(seconds: 5),
        persist: false,
        showCloseIcon: true,
        action: SnackBarAction(label: '重试', onPressed: onRetry),
      ),
    );
}
