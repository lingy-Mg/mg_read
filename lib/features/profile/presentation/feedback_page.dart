/// 意见反馈页面。
///
/// 职责：
/// - 说明当前版本不提供应用内反馈提交。
/// - 提供 GitHub Issues 入口，并始终交给系统外部浏览器打开。
///
/// 注意：
/// - 页面不收集、上传或持久化反馈内容。
/// - 标题栏固定在内容滚动区域之外，并由安全区和共享页面壳统一定位。
library;

import 'package:mg_read_motion/mg_read_motion.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/widgets/feedback_thanks_banner.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_detail_chrome.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

const String githubFeedbackUrl = 'https://github.com/lingy-Mg/mg_read/issues';

class FeedbackPage extends StatelessWidget {
  const FeedbackPage({required this.onBackRequested, required this.onDestinationRequested, super.key});

  final VoidCallback onBackRequested;

  /// 保留详情页公共导航边界，供既有路由调用方使用。
  final ValueChanged<AppNavigationDestination> onDestinationRequested;

  @override
  Widget build(BuildContext context) {
    return MotionScaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              ProfileDetailTopBar(title: '意见反馈', onBack: onBackRequested),
              Expanded(
                child: ListView(
                  key: const Key('feedback-page-content'),
                  padding: EdgeInsets.zero,
                  children: <Widget>[
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: AppDetailMetrics.horizontalPadding),
                      child: FeedbackThanksBanner(),
                    ),
                    const SizedBox(height: AppDetailMetrics.feedbackCardTopGap),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: AppDetailMetrics.horizontalPadding),
                      child: _GithubFeedbackCard(),
                    ),
                    const SizedBox(height: 24),
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

class _GithubFeedbackCard extends StatelessWidget {
  const _GithubFeedbackCard();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      key: const Key('feedback-github-card'),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.mutedText.withValues(alpha: 0.2), width: 0.8),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.forum_outlined, color: tokens.accent, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('当前不提供应用内提交', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Text(
                        '请在 GitHub Issues 中提交问题、功能建议或插件反馈。反馈内容会直接进入项目公开的讨论区。',
                        style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText, height: 1.6),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text('反馈地址', style: theme.textTheme.labelLarge?.copyWith(color: tokens.mutedText)),
            const SizedBox(height: 4),
            TextButton(
              key: const Key('feedback-github-link'),
              onPressed: () => _openGithubIssues(context),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                alignment: Alignment.centerLeft,
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(githubFeedbackUrl),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('feedback-open-github'),
                onPressed: () => _openGithubIssues(context),
                icon: const Icon(Icons.open_in_new_rounded, size: 19),
                label: const Text('在外部浏览器打开'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  backgroundColor: tokens.accent,
                  foregroundColor: theme.colorScheme.onPrimary,
                  shape: const RoundedRectangleBorder(borderRadius: AppRadii.detailControl),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openGithubIssues(BuildContext context) async {
  try {
    final bool launched = await launchUrl(Uri.parse(githubFeedbackUrl), mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) _showLaunchFailure(context);
  } catch (_) {
    if (context.mounted) _showLaunchFailure(context);
  }
}

void _showLaunchFailure(BuildContext context) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showMotionSnackBar(context, const SnackBar(content: Text('无法调用系统浏览器打开 GitHub 反馈地址。')));
}
