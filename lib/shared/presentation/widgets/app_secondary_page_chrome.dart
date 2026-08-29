/// 应用二级与三级页面的统一顶部栏和内容壳。
///
/// 职责：
/// - 对齐设置、数据源和其他二级页面的安全区、顶部节奏与返回操作。
/// - 统一窄屏与宽屏的内容宽度，避免各页面自行计算外侧间距。
///
/// 注意：
/// - 调用方只提供标题、操作和内容，不得叠加额外的顶部安全区或标题栏间距。
/// - Android 紧贴系统顶部安全区；其他平台保留八 dp 顶部节奏。
/// - 内容壳不负责路由、异步加载或业务状态。
/// - 二级及更深页面不得显示主导航栏。
///
/// TODO:
/// - 无。
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

/// The common title bar for profile-owned secondary pages.
///
/// The bar deliberately owns only presentation chrome. The surrounding page
/// must place it in [AppSecondaryPageContent] inside a top [SafeArea], so it
/// follows the same platform-aware rhythm as the primary profile header.
class AppSecondaryPageTopBar extends StatelessWidget {
  const AppSecondaryPageTopBar({
    required this.title,
    required this.onBack,
    this.actions = const <Widget>[],
    this.headerKey,
    this.backButtonKey,
    super.key,
  });

  final String title;
  final VoidCallback onBack;
  final List<Widget> actions;
  final Key? headerKey;
  final Key? backButtonKey;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      key: headerKey,
      height: AppSpacing.minimumTouchTarget,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Center(
            child: Semantics(
              header: true,
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
          Positioned(
            left: AppDetailMetrics.backButtonLeft,
            top: (AppSpacing.minimumTouchTarget - AppDetailMetrics.backButtonExtent) / 2,
            child: AppSecondaryPageIconButton(key: backButtonKey, label: '返回', icon: Icons.arrow_back_ios_new_rounded, onPressed: onBack),
          ),
          if (actions.isNotEmpty)
            Positioned(
              right: AppDetailMetrics.backButtonLeft,
              top: (AppSpacing.minimumTouchTarget - AppDetailMetrics.backButtonExtent) / 2,
              child: Row(mainAxisSize: MainAxisSize.min, children: actions),
            ),
        ],
      ),
    );
  }
}

/// A 48dp action slot used by secondary-page title bars.
class AppSecondaryPageIconButton extends StatelessWidget {
  const AppSecondaryPageIconButton({required this.label, required this.icon, required this.onPressed, super.key});

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: IconButton(
          onPressed: onPressed,
          tooltip: label,
          icon: Icon(icon),
          iconSize: 22,
          color: theme.colorScheme.onSurface,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: AppDetailMetrics.backButtonExtent, height: AppDetailMetrics.backButtonExtent),
        ),
      ),
    );
  }
}

/// Centers secondary-page content while preserving the compact phone layout.
///
/// Individual pages retain ownership of their inner list and card padding.
/// This shell provides the shared top rhythm, desktop gutter and maximum
/// readable width.
class AppSecondaryPageContent extends StatelessWidget {
  const AppSecondaryPageContent({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final double horizontalPadding = constraints.maxWidth >= AppSpacing.compactLayoutBreakpoint ? AppSpacing.widePagePadding : 0;
      return Padding(
        padding: EdgeInsets.fromLTRB(horizontalPadding, AppSpacing.pageHeaderTopPaddingFor(context), horizontalPadding, 0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppSpacing.contentMaxWidth),
            child: SizedBox(width: double.infinity, child: child),
          ),
        ),
      );
    },
  );
}

/// A small, consistent shell for secondary pages that are not implemented yet.
class AppSecondaryPlaceholderPage extends StatelessWidget {
  const AppSecondaryPlaceholderPage({
    required this.title,
    required this.description,
    required this.onBack,
    required this.onDestinationSelected,
    super.key,
  });

  final String title;
  final String description;
  final VoidCallback onBack;
  final ValueChanged<AppNavigationDestination> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              AppSecondaryPageTopBar(
                key: const Key('secondary-placeholder-top-bar'),
                title: title,
                onBack: onBack,
                backButtonKey: const Key('secondary-placeholder-back'),
              ),
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppDetailMetrics.horizontalPadding),
                    child: Semantics(
                      container: true,
                      label: '$title，功能建设中',
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(Icons.construction_outlined, size: 40, color: tokens.mutedText),
                          const SizedBox(height: AppSpacing.regular),
                          Text('功能建设中', style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: AppSpacing.unit),
                          Text(
                            description,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
                          ),
                        ],
                      ),
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
