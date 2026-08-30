/// 数据源插件 artifact 导入错误弹窗。
///
/// 职责：
/// - 将稳定应用错误码映射为双 artifact 格式的中文提示。
/// - 提供可复制错误码的统一导入失败弹窗。
///
/// 注意：
/// - 不展示原始异常、路径或文件内容。
/// - 文件内容是否合法最终由 Runtime 校验。
///
library;

import 'package:flutter/material.dart';

import 'package:mg_read/core/errors/app_error.dart';

Future<void> showPluginImportErrorDialog(BuildContext context, Object error) {
  final appError = AppError.fromUnknown(error);
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('数据源导入失败'),
      content: SelectableText(
        '${pluginImportErrorMessage(appError.code)}\n\n'
        '错误码：${appError.code.wireValue}',
      ),
      actions: <Widget>[TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('知道了'))],
    ),
  );
}

String pluginImportErrorMessage(AppErrorCode code) => switch (code) {
  AppErrorCode.invalidRequest || AppErrorCode.invalidFormat => '选择的文件不是有效的 MgRead 数据源，请确认文件后缀为 .mgplugin.js 或 .mgplugin，且文件没有损坏。',
  AppErrorCode.fileNameInvalid => '选择的文件名称不是 .mgplugin.js 或 .mgplugin。请重新选择 MgRead 数据源插件文件。',
  AppErrorCode.fileUnavailable => '手机找不到选择的文件。请把文件复制到手机本地存储后重新选择。',
  AppErrorCode.fileUnreadable || AppErrorCode.fileReadFailed => '手机无法读取选择的文件。请检查文件权限，并把文件复制到手机本地存储后重试。',
  AppErrorCode.fileTooLarge => '数据源插件文件超过 32 MB，无法导入。',
  AppErrorCode.pluginInstallFailed => '文件已经读取，但数据源插件安装失败。请确认这是标准 MgRead .mgplugin.js 或 .mgplugin 文件，并重新导出后再试。',
  AppErrorCode.diskFull => '手机存储空间不足，清理空间后再试。',
  AppErrorCode.runtimeStartFailed ||
  AppErrorCode.runtimeUnavailable ||
  AppErrorCode.runtimeNotReady => '数据源运行环境启动失败。请完全退出应用后重试；如果仍失败，请提供这个错误码。',
  _ => '导入过程遇到未分类错误，请提供这个错误码以便继续定位。',
};
