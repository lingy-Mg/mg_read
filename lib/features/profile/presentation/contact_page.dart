/// “关于我们”下的联系与反馈入口。
///
/// 职责：
/// - 告知用户当前可用的 GitHub 反馈渠道和反馈准备事项。
/// - 将用户带到反馈页面，由用户通过系统外部浏览器打开 GitHub Issues。
///
library;

import 'package:mg_read_motion/mg_read_motion.dart';
import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_detail_chrome.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

class ContactPage extends StatelessWidget {
  const ContactPage({required this.onBackRequested, required this.onFeedbackRequested, required this.appVersion, super.key});

  final VoidCallback onBackRequested;
  final VoidCallback onFeedbackRequested;
  final String appVersion;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return MotionScaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              ProfileDetailTopBar(title: '联系我们', onBack: onBackRequested),
              Expanded(
                child: ListView(
                  key: const Key('contact-page-content'),
                  padding: const EdgeInsets.fromLTRB(AppDetailMetrics.horizontalPadding, 24, AppDetailMetrics.horizontalPadding, 32),
                  children: <Widget>[
                    Icon(Icons.headset_mic_outlined, color: tokens.accent, size: 54),
                    const SizedBox(height: 14),
                    Text(
                      '我们重视每一条反馈',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '遇到功能问题或有改进建议时，可通过 GitHub Issues 告诉我们。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText, height: 1.6),
                    ),
                    const SizedBox(height: 28),
                    _ContactCard(
                      icon: Icons.edit_note_outlined,
                      title: 'GitHub Issues 反馈',
                      body: '反馈页面会提供项目 GitHub Issues 地址，并使用系统外部浏览器打开，不在应用内收集反馈内容。',
                    ),
                    const SizedBox(height: 12),
                    const _ContactCard(
                      icon: Icons.fact_check_outlined,
                      title: '反馈前建议',
                      body: '请尽量说明出现问题的页面、操作步骤、期望结果和实际结果；如包含日志或截图，请先检查其中是否有敏感信息。',
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      key: const Key('contact-open-feedback'),
                      onPressed: onFeedbackRequested,
                      icon: const Icon(Icons.arrow_forward_rounded, size: 20),
                      label: const Text('打开 GitHub 反馈'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: tokens.accent,
                        foregroundColor: theme.colorScheme.onPrimary,
                        shape: const RoundedRectangleBorder(borderRadius: AppRadii.detailControl),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      '统一阅读 · 版本 $appVersion',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContactCard extends StatelessWidget {
  const _ContactCard({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.mutedText.withValues(alpha: 0.16), width: 0.8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, color: tokens.accent, size: 25),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 7),
                  Text(body, style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText, height: 1.65)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
