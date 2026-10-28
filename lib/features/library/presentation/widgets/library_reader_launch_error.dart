/// 书架阅读启动失败提示。
/// 提示由当前 ScaffoldMessenger 持有，五秒后自动消失，也可关闭或重试；
/// 连续失败替换待显示提示，避免错误队列持续占据页面。组件不持有启动任务或 IO。
library;

import 'package:flutter/material.dart';

void showLibraryReaderLaunchError(BuildContext context, {required String message, required VoidCallback onRetry}) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message, maxLines: 4, overflow: TextOverflow.ellipsis),
        duration: const Duration(seconds: 5),
        persist: false,
        showCloseIcon: true,
        action: SnackBarAction(label: '重试', onPressed: onRetry),
      ),
    );
}
