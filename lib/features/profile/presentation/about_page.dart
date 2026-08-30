/// 关于我们页面。
///
/// 职责：
/// - 展示应用信息和可继续进入的关于条目。
/// - 复用设置子页面的固定标题栏与内容宽度。
///
/// 注意：
/// - 标题栏位于滚动区域之外，不能随内容离开顶部。
/// - 不直接打开网络、外部页面或未定义的 Runtime 能力。
///
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_detail_chrome.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({required this.onBackRequested, required this.onDestinationRequested, this.onItemRequested, super.key});

  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final ValueChanged<String>? onItemRequested;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              ProfileDetailTopBar(title: '关于我们', onBack: onBackRequested),
              Expanded(
                child: ListView(
                  key: const Key('about-page-content'),
                  padding: EdgeInsets.zero,
                  children: <Widget>[
                    const SizedBox(height: AppDetailMetrics.aboutIconTopGap),
                    const Align(child: _AboutAppIcon()),
                    const SizedBox(height: 15),
                    Text(
                      '统一阅读',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                        letterSpacing: -0.35,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      '版本 1.2.0',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: tokens.mutedText,
                        fontWeight: FontWeight.w400,
                        height: 1.35,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '书山有路勤为径，阅读点亮生活。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: tokens.mutedText,
                        fontWeight: FontWeight.w400,
                        height: 1.5,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: AppDetailMetrics.aboutCardTopGap),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: AppDetailMetrics.horizontalPadding),
                      child: _AboutSettingsCard(
                        onItemPressed: (String itemId) {
                          final callback = onItemRequested;
                          if (callback != null) {
                            callback(itemId);
                            return;
                          }
                          _showUnavailable(context);
                        },
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '© 2018–2024 统一阅读',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: tokens.mutedText,
                        fontWeight: FontWeight.w400,
                        height: 1.5,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '保留所有权利',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: tokens.mutedText,
                        fontWeight: FontWeight.w400,
                        height: 1.5,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 18),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showUnavailable(BuildContext context) {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('相关内容尚未接入，当前不会打开网络或外部页面。')));
  }
}

class _AboutAppIcon extends StatelessWidget {
  const _AboutAppIcon();

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      image: true,
      label: '统一阅读应用图标',
      child: ExcludeSemantics(
        child: Container(
          key: const Key('about-app-icon'),
          width: AppDetailMetrics.aboutIconExtent,
          height: AppDetailMetrics.aboutIconExtent,
          decoration: BoxDecoration(
            borderRadius: AppRadii.detailAppIcon,
            border: Border.all(color: tokens.warning.withValues(alpha: 0.16), width: 0.8),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                Color.alphaBlend(tokens.featureSurface.withValues(alpha: 0.78), tokens.surface),
                Color.lerp(tokens.featureSurface, tokens.warning, 0.015)!,
              ],
            ),
            boxShadow: <BoxShadow>[BoxShadow(color: tokens.shadow.withValues(alpha: 0.14), blurRadius: 15, offset: const Offset(0, 6))],
          ),
          clipBehavior: Clip.antiAlias,
          child: Image.asset('assets/branding/mg_read_logo.png', fit: BoxFit.cover),
        ),
      ),
    );
  }
}

class _AboutSettingsCard extends StatelessWidget {
  const _AboutSettingsCard({required this.onItemPressed});

  final ValueChanged<String> onItemPressed;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final List<_AboutItem> items = <_AboutItem>[
      const _AboutItem(id: 'agreement', title: '用户协议', icon: Icons.description_outlined),
      const _AboutItem(id: 'privacy', title: '隐私政策', icon: Icons.shield_outlined),
      const _AboutItem(id: 'licenses', title: '开源许可', icon: Icons.code_rounded),
      const _AboutItem(id: 'contact', title: '联系我们', icon: Icons.headset_mic_outlined),
    ];

    return SizedBox(
      key: const Key('about-settings-card'),
      height: items.length * AppDetailMetrics.aboutRowHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: AppRadii.detailCard,
          border: Border.all(color: tokens.mutedText.withValues(alpha: 0.2), width: 0.8),
        ),
        child: ClipRRect(
          borderRadius: AppRadii.detailCard,
          child: Column(
            children: List<Widget>.generate(items.length, (int index) {
              return _AboutSettingsRow(
                item: items[index],
                showDivider: index < items.length - 1,
                onPressed: () => onItemPressed(items[index].id),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _AboutSettingsRow extends StatelessWidget {
  const _AboutSettingsRow({required this.item, required this.showDivider, required this.onPressed});

  final _AboutItem item;
  final bool showDivider;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      height: AppDetailMetrics.aboutRowHeight,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: ValueKey<String>('about-action-${item.id}'),
                onTap: onPressed,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: <Widget>[
                      SizedBox(width: 24, child: Icon(item.icon, color: tokens.warning, size: 23)),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.onSurface,
                            fontWeight: FontWeight.w500,
                            height: 1.2,
                            letterSpacing: 0,
                          ),
                        ),
                      ),
                      const SizedBox(width: 11),
                      Icon(Icons.arrow_forward_ios_rounded, color: tokens.mutedText, size: 15),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (showDivider)
            Positioned(
              left: 14,
              right: 14,
              bottom: 0,
              child: SizedBox(height: 0.8, child: ColoredBox(color: tokens.mutedText.withValues(alpha: 0.15))),
            ),
        ],
      ),
    );
  }
}

class _AboutItem {
  const _AboutItem({required this.id, required this.title, required this.icon});

  final String id;
  final String title;
  final IconData icon;
}
