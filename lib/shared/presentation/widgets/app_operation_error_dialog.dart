/// 可复用的全局操作失败弹窗。
///
/// 职责：
/// - 在根 Navigator 上展示用户可关闭、可复制实际失败原因的操作错误。
/// - 保留稳定错误码以及未经泛化替换的原始错误文本，供用户反馈。
///
/// 注意：
/// - 调用方仍拥有操作重试、状态回滚和诊断记录；本组件只负责展示。
/// - 复制能力失败不得覆盖原始业务错误或阻止用户关闭弹窗。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mg_read/core/errors/app_error.dart';

typedef AppOperationErrorCopy = Future<void> Function(String payload);

/// Shows a root-modal error dialog for one user-triggered operation.
Future<void> showAppOperationErrorDialog(
  BuildContext context, {
  required String operation,
  required Object error,
  String? guidance,
  AppOperationErrorCopy copyError = _copyToClipboard,
}) {
  final details = AppOperationErrorDetails.fromError(operation: operation, error: error);
  return showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (BuildContext dialogContext) =>
        AppOperationErrorDialog(details: details, guidance: guidance, onCopy: () => copyError(details.copyPayload)),
  );
}

Future<void> _copyToClipboard(String payload) => Clipboard.setData(ClipboardData(text: payload));

/// Immutable, copyable error information displayed by [AppOperationErrorDialog].
final class AppOperationErrorDetails {
  AppOperationErrorDetails._({required this.operation, required this.error, required this.reason});

  factory AppOperationErrorDetails.fromError({required String operation, required Object error}) {
    final appError = AppError.fromUnknown(error);
    final reason = appError.detail?.trim();
    return AppOperationErrorDetails._(
      operation: operation,
      error: appError,
      reason: reason == null || reason.isEmpty ? error.toString() : reason,
    );
  }

  final String operation;
  final AppError error;
  final String reason;

  String get copyPayload => '操作：$operation\n错误码：${error.code.wireValue}\n错误原因：$reason';
}

/// A selectable error reason and an explicit copy action for app operations.
final class AppOperationErrorDialog extends StatelessWidget {
  const AppOperationErrorDialog({required this.details, this.guidance, required this.onCopy, super.key});

  final AppOperationErrorDetails details;
  final String? guidance;
  final Future<void> Function() onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('${details.operation}失败'),
      content: SelectionArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(guidance ?? '操作未能完成，请稍后重试。', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            Text('错误原因', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            SelectableText(details.reason, key: const Key('app-operation-error-reason')),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(key: const Key('app-operation-error-copy'), onPressed: () => unawaited(_copySafely()), child: const Text('复制错误原因')),
        FilledButton(
          key: const Key('app-operation-error-close'),
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Future<void> _copySafely() async {
    try {
      await onCopy();
    } catch (_) {
      // Clipboard availability must not prevent dismissing an operation error.
    }
  }
}
