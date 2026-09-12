/// 发现页内容状态展示。
///
/// 职责：
/// - 渲染稳定的加载、空态和失败态。
/// - 在等待期间保留页面层级，不伪造进度或持续脉冲。
/// - 失败详情左对齐并支持文本选择和一键复制。
///
/// 注意：
/// - 只接收展示状态和显式重试回调，不发起 IO。
/// - 外层页面负责入场/返回过渡和无障碍 reduce motion。
///
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/widgets/app_loading_state.dart';

typedef DiscoveryFailureCopy = Future<void> Function(String payload);

class DiscoveryContentState extends StatelessWidget {
  const DiscoveryContentState({
    required this.isLoading,
    required this.isEmpty,
    required this.onRetry,
    this.failureMessage,
    this.failureDetail,
    this.failureCode,
    this.failureCopyPayload,
    this.onCopy = _copyToClipboard,
    super.key,
  });

  final bool isLoading;
  final bool isEmpty;
  final String? failureMessage;
  final String? failureDetail;
  final String? failureCode;
  final String? failureCopyPayload;
  final DiscoveryFailureCopy onCopy;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const AppLoadingState(key: Key('discovery-loading-content'), label: '正在加载发现内容', message: '插件正在生成分区、榜单和分类。');
    }
    final failureMessageText = failureMessage ?? '当前来源没有发现内容。';
    final copyPayloadParts = <String>[failureMessageText];
    if (failureDetail case final detail?) copyPayloadParts.add(detail);
    if (failureCode case final code?) copyPayloadParts.add('稳定错误码：$code');
    final copyPayload = failureCopyPayload ?? copyPayloadParts.join('\n');

    return SelectionArea(
      child: Column(
        key: Key(isEmpty ? 'discovery-empty' : 'discovery-failure'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: Icon(
              isEmpty ? Icons.inbox_outlined : Icons.error_outline_rounded,
              size: 40,
              color: AppThemeTokens.of(context).mutedText,
            ),
          ),
          const SizedBox(height: AppSpacing.regular),
          Text(failureMessageText, textAlign: TextAlign.left, style: Theme.of(context).textTheme.titleMedium),
          if (failureDetail case final detail?) ...<Widget>[
            const SizedBox(height: AppSpacing.compact),
            SelectableText(
              detail,
              key: const Key('discovery-failure-detail'),
              textAlign: TextAlign.left,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppThemeTokens.of(context).mutedText),
            ),
          ],
          if (failureCode case final code?) ...<Widget>[
            const SizedBox(height: AppSpacing.unit),
            SelectableText(
              '稳定错误码：$code',
              key: const Key('discovery-failure-code'),
              textAlign: TextAlign.left,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: AppSpacing.regular),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (!isEmpty)
                TextButton(
                  key: const Key('discovery-failure-copy'),
                  onPressed: () => unawaited(_copySafely(copyPayload)),
                  child: const Text('复制诊断信息'),
                ),
              TextButton(onPressed: onRetry, child: const Text('刷新')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _copySafely(String payload) async {
    try {
      await onCopy(payload);
    } catch (_) {
      // Clipboard availability must not prevent retrying the discovery request.
    }
  }
}

Future<void> _copyToClipboard(String payload) => Clipboard.setData(ClipboardData(text: payload));
