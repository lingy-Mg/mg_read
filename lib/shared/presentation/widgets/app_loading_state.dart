/// 页面加载反馈；无动画模式保留静态等待图标，不伪造进度或阻塞真实任务。
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';

/// Shared centered loading presentation used by feature pages.
class AppLoadingState extends StatelessWidget {
  const AppLoadingState({required this.label, required this.message, this.progressKey, super.key});

  final String label;
  final String message;
  final Key? progressKey;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Center(
      child: Semantics(
        label: label,
        liveRegion: true,
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.section),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                AppMotion.disablesAnimations(context)
                    ? Icon(Icons.hourglass_empty_rounded, key: progressKey, color: tokens.accent, size: 36)
                    : CircularProgressIndicator(key: progressKey, color: tokens.accent),
                const SizedBox(height: AppSpacing.regular),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
