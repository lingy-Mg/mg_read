/// “关于我们”下的本地协议与隐私说明页面。
///
/// 职责：
/// - 展示随应用发布、无需联网即可阅读的用户协议和隐私政策。
/// - 保持三级页面与个人中心详情页一致的顶部栏和内容宽度。
///
/// 注意：
/// - 正文只描述当前应用边界，不承诺未接入的账号、云同步或客服能力。
/// - 内容变化应同步更新页面中的更新日期。
///
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_detail_chrome.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

enum AboutDocumentKind { agreement, privacy }

class AboutDocumentPage extends StatelessWidget {
  const AboutDocumentPage({required this.kind, required this.onBackRequested, super.key});

  final AboutDocumentKind kind;
  final VoidCallback onBackRequested;

  @override
  Widget build(BuildContext context) {
    final _AboutDocument document = _documentFor(kind);
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              ProfileDetailTopBar(title: document.title, onBack: onBackRequested),
              Expanded(
                child: ListView(
                  key: ValueKey<String>('about-document-${kind.name}'),
                  padding: const EdgeInsets.fromLTRB(AppDetailMetrics.horizontalPadding, 16, AppDetailMetrics.horizontalPadding, 32),
                  children: <Widget>[
                    _DocumentIntro(document: document),
                    const SizedBox(height: 14),
                    for (int index = 0; index < document.sections.length; index++) ...<Widget>[
                      _DocumentSection(index: index + 1, section: document.sections[index]),
                      if (index < document.sections.length - 1) const SizedBox(height: 12),
                    ],
                    const SizedBox(height: 18),
                    Text(
                      '更新日期：2026 年 8 月 30 日',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText, height: 1.5),
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

class _DocumentIntro extends StatelessWidget {
  const _DocumentIntro({required this.document});

  final _AboutDocument document;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.featureSurface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.warning.withValues(alpha: 0.16), width: 0.8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(color: tokens.warning.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: Icon(document.icon, color: tokens.warning, size: 23),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                document.introduction,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface, height: 1.65),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DocumentSection extends StatelessWidget {
  const _DocumentSection({required this.index, required this.section});

  final int index;
  final _AboutDocumentSection section;

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
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('$index. ${section.title}', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.35)),
            const SizedBox(height: 8),
            Text(section.body, style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText, height: 1.75)),
          ],
        ),
      ),
    );
  }
}

_AboutDocument _documentFor(AboutDocumentKind kind) => switch (kind) {
  AboutDocumentKind.agreement => const _AboutDocument(
    title: '用户协议',
    icon: Icons.description_outlined,
    introduction: '欢迎使用统一阅读。请在使用前阅读本协议；继续使用应用，表示你理解并同意按照以下规则使用相关功能。',
    sections: <_AboutDocumentSection>[
      _AboutDocumentSection(title: '服务内容', body: '统一阅读提供本地书架、阅读记录、阅读设置、内容导入以及已启用数据源的统一访问界面。具体功能会随版本调整，第三方内容是否可用由对应内容提供方决定。'),
      _AboutDocumentSection(title: '使用规范', body: '你应遵守适用法律法规和内容提供方规则，不得利用本应用侵害他人权益、干扰服务运行，或获取、传播无权使用的内容。'),
      _AboutDocumentSection(title: '本地数据与备份', body: '书架、阅读进度、历史记录和设置主要保存在当前设备。请根据需要使用应用内导入导出或局域网同步功能自行备份；卸载应用、清除数据或设备故障可能造成数据丢失。'),
      _AboutDocumentSection(title: '第三方内容', body: '数据源、网页和外部链接由第三方提供并适用其各自规则。统一阅读不编辑这些内容，也不保证第三方服务持续可用、准确或完整。'),
      _AboutDocumentSection(title: '功能变更与停止使用', body: '为改进体验、安全性或兼容性，应用功能可能更新、调整或停止提供。若你不同意更新后的规则，可以停止使用相关功能并移除本地数据。'),
      _AboutDocumentSection(title: '问题反馈', body: '如对本协议或应用功能有疑问，可通过个人中心的“意见反馈”页面说明问题。提交前请避免填写不必要的敏感个人信息。'),
    ],
  ),
  AboutDocumentKind.privacy => const _AboutDocument(
    title: '隐私政策',
    icon: Icons.shield_outlined,
    introduction: '统一阅读重视你的隐私。本说明介绍当前版本在提供阅读、数据源和设备内管理功能时会处理哪些数据，以及你可以如何管理这些数据。',
    sections: <_AboutDocumentSection>[
      _AboutDocumentSection(title: '设备内数据', body: '应用会在设备上保存书架、阅读进度、历史记录、偏好设置、数据源配置、缓存和运行诊断信息，用于恢复状态、离线阅读、故障定位和提升使用体验。'),
      _AboutDocumentSection(title: '网络与数据源', body: '当你主动搜索、发现或阅读数据源内容时，必要的搜索词、内容标识和网络请求会发送给你选择的数据源或其内容服务器。第三方如何处理数据，以其自身规则为准。'),
      _AboutDocumentSection(title: '设备权限', body: '只有在你使用对应功能时，应用才会请求必要权限，例如导入导出时访问所选文件、扫码连接时使用相机。拒绝权限只会影响依赖该权限的功能。'),
      _AboutDocumentSection(title: '反馈信息', body: '意见反馈页面允许你自行填写问题描述和联系方式。当前页面会明确告知提交能力的实际状态；在服务未接入时，内容不会被宣称已经发送。'),
      _AboutDocumentSection(title: '数据共享', body: '当前版本未接入统一阅读账号或云端用户资料服务。应用不会主动出售你的个人信息；但你访问第三方数据源、打开外部内容或使用系统分享时，相关数据会按你的操作发送给对应接收方。'),
      _AboutDocumentSection(title: '管理与删除', body: '你可以在应用内清理缓存、管理书架与历史记录，并通过系统能力删除应用数据。需要保留的信息请先完成导出或其他备份。'),
      _AboutDocumentSection(title: '政策更新', body: '当数据处理范围或应用能力发生实质变化时，本页面会同步更新。建议在版本升级后重新查看本说明。'),
    ],
  ),
};

class _AboutDocument {
  const _AboutDocument({required this.title, required this.icon, required this.introduction, required this.sections});

  final String title;
  final IconData icon;
  final String introduction;
  final List<_AboutDocumentSection> sections;
}

class _AboutDocumentSection {
  const _AboutDocumentSection({required this.title, required this.body});

  final String title;
  final String body;
}
