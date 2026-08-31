/// 发现页内容状态展示。
///
/// 职责：
/// - 渲染稳定的加载、空态和失败态。
/// - 在等待期间保留页面层级，不伪造进度或持续脉冲。
///
/// 注意：
/// - 只接收展示状态和显式重试回调，不发起 IO。
/// - 外层页面负责入场/返回过渡和无障碍 reduce motion。
///
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/widgets/app_loading_state.dart';

class DiscoveryContentState extends StatelessWidget {
  const DiscoveryContentState({
    required this.isLoading,
    required this.isEmpty,
    required this.onRetry,
    this.failureMessage,
    this.failureDetail,
    this.failureCode,
    super.key,
  });

  final bool isLoading;
  final bool isEmpty;
  final String? failureMessage;
  final String? failureDetail;
  final String? failureCode;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const AppLoadingState(key: Key('discovery-loading-content'), label: '正在加载发现内容', message: '插件正在生成分区、榜单和分类。');
    }
    return Column(
      key: Key(isEmpty ? 'discovery-empty' : 'discovery-failure'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(isEmpty ? Icons.inbox_outlined : Icons.error_outline_rounded, size: 40, color: AppThemeTokens.of(context).mutedText),
        const SizedBox(height: AppSpacing.regular),
        Text(failureMessage ?? '当前来源没有发现内容。', textAlign: TextAlign.center),
        if (failureDetail != null) ...<Widget>[
          const SizedBox(height: AppSpacing.compact),
          Text(
            failureDetail!,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppThemeTokens.of(context).mutedText),
          ),
        ],
        if (failureCode != null) ...<Widget>[
          const SizedBox(height: AppSpacing.unit),
          Text('稳定错误码：$failureCode', style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: AppSpacing.regular),
        TextButton(onPressed: onRetry, child: const Text('刷新')),
      ],
    );
  }
}
