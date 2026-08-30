/// “关于我们”下的实际开源许可页面。
///
/// 职责：
/// - 从 Flutter [LicenseRegistry] 读取随当前构建注册的依赖许可。
/// - 按许可条目渐进展开正文，避免首帧一次性构建全部长文本。
///
/// 注意：
/// - 不维护手写依赖清单；构建中实际注册的许可是唯一数据来源。
///
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_detail_chrome.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

class OpenSourceLicensesPage extends StatefulWidget {
  const OpenSourceLicensesPage({required this.onBackRequested, super.key});

  final VoidCallback onBackRequested;

  @override
  State<OpenSourceLicensesPage> createState() => _OpenSourceLicensesPageState();
}

class _OpenSourceLicensesPageState extends State<OpenSourceLicensesPage> {
  late final Future<List<_RegisteredLicense>> _licenses = _loadLicenses();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              ProfileDetailTopBar(title: '开源许可', onBack: widget.onBackRequested),
              Expanded(
                child: FutureBuilder<List<_RegisteredLicense>>(
                  future: _licenses,
                  builder: (BuildContext context, AsyncSnapshot<List<_RegisteredLicense>> snapshot) {
                    if (snapshot.hasError) return const _LicenseMessage(icon: Icons.error_outline, message: '许可信息读取失败，请稍后重试。');
                    final licenses = snapshot.data;
                    if (licenses == null) return const Center(child: CircularProgressIndicator());
                    if (licenses.isEmpty) return const _LicenseMessage(icon: Icons.code_rounded, message: '当前构建没有注册可展示的许可信息。');
                    return _LicenseList(licenses: licenses);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<List<_RegisteredLicense>> _loadLicenses() async {
    final entries = await LicenseRegistry.licenses.toList();
    return <_RegisteredLicense>[
      for (final entry in entries)
        _RegisteredLicense(
          packages: (entry.packages.toList()..sort()).join('、'),
          paragraphs: <String>[for (final paragraph in entry.paragraphs) paragraph.text],
        ),
    ];
  }
}

class _LicenseList extends StatelessWidget {
  const _LicenseList({required this.licenses});

  final List<_RegisteredLicense> licenses;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return ListView.builder(
      key: const Key('open-source-license-list'),
      padding: const EdgeInsets.fromLTRB(AppDetailMetrics.horizontalPadding, 14, AppDetailMetrics.horizontalPadding, 32),
      itemCount: licenses.length + 1,
      itemBuilder: (BuildContext context, int index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              '统一阅读使用了以下开源软件。点按条目可查看随当前构建注册的完整许可文本。',
              style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText, height: 1.6),
            ),
          );
        }
        final license = licenses[index - 1];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Material(
            color: tokens.surface,
            shape: RoundedRectangleBorder(
              borderRadius: AppRadii.detailCard,
              side: BorderSide(color: tokens.mutedText.withValues(alpha: 0.16), width: 0.8),
            ),
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
              key: ValueKey<String>('open-source-license-${index - 1}'),
              iconColor: tokens.warning,
              collapsedIconColor: tokens.mutedText,
              title: Text(license.packages.isEmpty ? '未命名组件' : license.packages, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('${license.paragraphs.length} 段许可文本', style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
              children: <Widget>[
                const Divider(height: 1),
                const SizedBox(height: 14),
                for (int paragraphIndex = 0; paragraphIndex < license.paragraphs.length; paragraphIndex++) ...<Widget>[
                  SelectableText(license.paragraphs[paragraphIndex], style: theme.textTheme.bodySmall?.copyWith(height: 1.55)),
                  if (paragraphIndex < license.paragraphs.length - 1) const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LicenseMessage extends StatelessWidget {
  const _LicenseMessage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppDetailMetrics.horizontalPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, color: tokens.mutedText, size: 40),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
            ),
          ],
        ),
      ),
    );
  }
}

class _RegisteredLicense {
  const _RegisteredLicense({required this.packages, required this.paragraphs});

  final String packages;
  final List<String> paragraphs;
}
