/// “关于我们”三级入口的页面分发器。
///
/// 职责：
/// - 将稳定条目标识映射到用户协议、隐私政策、开源许可和联系页面。
/// - 为无效深链提供可返回的明确错误页。
///
/// 注意：
/// - 本入口不包含版本检查；新增条目时需同时更新关于页可见列表和路由测试。
///
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/about_document_page.dart';
import 'package:mg_read/features/profile/presentation/contact_page.dart';
import 'package:mg_read/features/profile/presentation/open_source_licenses_page.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_detail_chrome.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

class AboutItemPage extends StatelessWidget {
  const AboutItemPage({
    required this.itemId,
    required this.onBackRequested,
    required this.onFeedbackRequested,
    required this.appVersion,
    super.key,
  });

  final String itemId;
  final VoidCallback onBackRequested;
  final VoidCallback onFeedbackRequested;
  final String appVersion;

  @override
  Widget build(BuildContext context) => switch (itemId) {
    'agreement' => AboutDocumentPage(kind: AboutDocumentKind.agreement, onBackRequested: onBackRequested),
    'privacy' => AboutDocumentPage(kind: AboutDocumentKind.privacy, onBackRequested: onBackRequested),
    'licenses' => OpenSourceLicensesPage(onBackRequested: onBackRequested),
    'contact' => ContactPage(onBackRequested: onBackRequested, onFeedbackRequested: onFeedbackRequested, appVersion: appVersion),
    _ => _UnknownAboutItemPage(onBackRequested: onBackRequested),
  };
}

class _UnknownAboutItemPage extends StatelessWidget {
  const _UnknownAboutItemPage({required this.onBackRequested});

  final VoidCallback onBackRequested;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              ProfileDetailTopBar(title: '关于我们', onBack: onBackRequested),
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppDetailMetrics.horizontalPadding),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.link_off_rounded, color: tokens.mutedText, size: 40),
                        const SizedBox(height: 12),
                        Text('页面不存在', style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 6),
                        Text('该关于条目不存在或已被移除。', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
