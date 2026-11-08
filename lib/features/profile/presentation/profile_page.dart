/// “我的”主页面。
///
/// 职责：
/// - 顶层只保留设置分类，具体选项在分类与设置子页中逐级展开。
/// - 概览卡提供局域网同步快捷入口，完整连接工具在分类页中展示。
/// - 作为设置子页面的顶部节奏基准。
///
/// 注意：
/// - 不在 build() 中读取或写入持久化、Runtime 数据。
/// - 根页与二级页必须消费同一顶部间距和最小操作命中区 token。
/// - TV 模式交给电视设置面板，沿用相同设置和导航回调。
///
library;

import 'package:flutter/material.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/profile_view_data.dart';
import 'package:mg_read/features/profile/presentation/profile_settings_catalog.dart';
import 'package:mg_read/features/profile/presentation/tv_profile_page.dart';
import 'package:mg_read/features/profile/domain/profile_identity.dart';
import 'package:mg_read/features/profile/domain/profile_reading_stats.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_overview_card.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_settings_list.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';
import 'package:mg_read/shared/presentation/widgets/app_page_backdrop.dart';
import 'package:mg_read/shared/presentation/widgets/app_page_title.dart';

class ProfilePage extends StatefulWidget {
  /// Creates the profile page and delegates root navigation to the app layer.
  const ProfilePage({
    this.onDestinationRequested,
    this.onToggleTheme,
    this.onAboutRequested,
    this.onFeedbackRequested,
    this.onPluginCenterRequested,
    this.onPluginCacheRequested,
    this.onImportExportRequested,
    this.onLanSyncRequested,
    this.onPendingSettingRequested,
    this.onDiagnosticsRequested,
    this.onEditRequested,
    required this.appVersion,
    this.profileIdentity = ProfileIdentity.defaults,
    this.readingStats,
    super.key,
  });

  final ValueChanged<AppNavigationDestination>? onDestinationRequested;

  /// Test-friendly override for the app-level temporary theme action.
  final VoidCallback? onToggleTheme;

  final VoidCallback? onAboutRequested;
  final VoidCallback? onFeedbackRequested;
  final VoidCallback? onPluginCenterRequested;
  final VoidCallback? onPluginCacheRequested;
  final VoidCallback? onImportExportRequested;
  final VoidCallback? onLanSyncRequested;
  final ValueChanged<String>? onPendingSettingRequested;
  final VoidCallback? onDiagnosticsRequested;
  final VoidCallback? onEditRequested;
  final String appVersion;
  final ProfileIdentity profileIdentity;

  /// Local Content Library totals when this page is created by the app route.
  final ProfileReadingStats? readingStats;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final ScrollController _scrollController = ScrollController();
  String? _actionFeedback;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (TvModeScope.isEnabled(context)) {
      return TvProfilePage(
        appVersion: widget.appVersion,
        onDestinationRequested: _handleDestinationSelected,
        onSettingRequested: _handleSettingsItemPressed,
        onAboutRequested: _handleAboutItemPressed,
      );
    }
    var data = ProfileFixtures.preview.withIdentity(widget.profileIdentity).withAppVersion(widget.appVersion);
    if (widget.readingStats case final stats?) {
      data = data.withReadingStats(stats);
    }
    return Scaffold(
      extendBody: !TvModeScope.isEnabled(context),
      body: AppPageBackdrop(
        style: AppPageBackdropStyle.profile,
        child: SafeArea(
          bottom: false,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool useWidePagePadding = constraints.maxWidth >= AppSpacing.compactLayoutBreakpoint;
              final double pagePadding = useWidePagePadding ? AppSpacing.widePagePadding : AppSpacing.compactPagePadding;
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: AppSpacing.contentMaxWidth),
                  child: SizedBox(
                    width: double.infinity,
                    child: Scrollbar(
                      controller: _scrollController,
                      thumbVisibility: false,
                      thickness: AppSpacing.unit - 1,
                      radius: const Radius.circular(AppSpacing.unit - 1),
                      child: ListView(
                        key: const Key('profile-page-content'),
                        controller: _scrollController,
                        primary: false,
                        padding: EdgeInsets.fromLTRB(
                          pagePadding,
                          AppSpacing.pageHeaderTopPaddingFor(context),
                          pagePadding,
                          AppSpacing.profileContentBottomSafeDistance + MediaQuery.viewPaddingOf(context).bottom,
                        ),
                        children: <Widget>[
                          ProfileTopBar(onToggleTheme: widget.onToggleTheme),
                          const SizedBox(height: AppSpacing.compact + 2),
                          ProfileOverviewCard(
                            data: data,
                            onEdit: widget.onEditRequested ?? _showUnavailableMessage,
                            onSyncPressed: widget.onLanSyncRequested ?? _showUnavailableMessage,
                          ),
                          if (_actionFeedback != null) ...<Widget>[
                            const SizedBox(height: AppSpacing.regular),
                            _ProfileActionFeedback(
                              message: _actionFeedback!,
                              onDismiss: () {
                                setState(() {
                                  _actionFeedback = null;
                                });
                              },
                            ),
                          ],
                          const SizedBox(height: AppSpacing.section - 2),
                          ..._settingsGroup('设置', ProfileSettingsCatalog.categories),
                          const SizedBox(height: AppSpacing.section - 4),
                          _ProfileSectionTitle(title: '关于与其他'),
                          const SizedBox(height: AppSpacing.comfortable / 2),
                          ProfileSettingsList(
                            items: data.about.where((item) => item.id != 'diagnostics').toList(),
                            onItemPressed: _handleAboutItemPressed,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: AppBottomNavigation(selected: AppNavigationDestination.profile, onSelected: _handleDestinationSelected),
      ),
    );
  }

  List<Widget> _settingsGroup(String title, List<ProfileSettingsItemViewData> items) => [
    _ProfileSectionTitle(title: title),
    const SizedBox(height: AppSpacing.comfortable / 2),
    ProfileSettingsList(items: items, onItemPressed: _handleSettingsItemPressed),
    const SizedBox(height: AppSpacing.comfortable),
  ];

  void _handleDestinationSelected(AppNavigationDestination destination) {
    if (destination == AppNavigationDestination.profile) {
      return;
    }
    final ValueChanged<AppNavigationDestination>? destinationRequested = widget.onDestinationRequested;
    if (destinationRequested != null) {
      destinationRequested(destination);
      return;
    }
    _showUnavailableMessage();
  }

  void _showUnavailableMessage() {
    setState(() {
      _actionFeedback = '此操作尚未接入真实数据，可由后续功能替换。';
    });
  }

  void _handleAboutItemPressed(ProfileSettingsItemViewData item) {
    final VoidCallback? callback = switch (item.id) {
      'about' => widget.onAboutRequested,
      'feedback' => widget.onFeedbackRequested,
      'diagnostics' => widget.onDiagnosticsRequested,
      _ => null,
    };
    if (callback != null) {
      callback();
      return;
    }
    _showUnavailableMessage();
  }

  void _handleSettingsItemPressed(ProfileSettingsItemViewData item) {
    if (item.id == 'source-management' && widget.onPluginCenterRequested != null) {
      widget.onPluginCenterRequested!();
      return;
    }
    if (item.id == 'downloads-cache' && widget.onPluginCacheRequested != null) {
      widget.onPluginCacheRequested!();
      return;
    }
    if (item.id == 'import-export' && widget.onImportExportRequested != null) {
      widget.onImportExportRequested!();
      return;
    }
    if (item.id == 'data-backup' && widget.onLanSyncRequested != null) {
      widget.onLanSyncRequested!();
      return;
    }
    final ValueChanged<String>? onPendingSettingRequested = widget.onPendingSettingRequested;
    if (onPendingSettingRequested != null) {
      onPendingSettingRequested(item.id);
      return;
    }
    _showUnavailableMessage();
  }
}

/// The profile page header with its optional theme action.
class ProfileTopBar extends StatelessWidget {
  /// Creates the title and fixed-size top actions.
  const ProfileTopBar({required this.onToggleTheme, super.key});

  final VoidCallback? onToggleTheme;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      height: AppSpacing.minimumTouchTarget,
      child: Row(
        children: <Widget>[
          const Expanded(child: AppPageTitle(title: '我的')),
          if (onToggleTheme == null) const _ProfileTopBarDecoration(),
          if (onToggleTheme != null) ...<Widget>[
            _ProfileTopBarAction(
              key: const Key('theme-mode-toggle'),
              tooltip: theme.brightness == Brightness.dark ? '切换至浅色模式' : '切换至深色模式',
              onPressed: onToggleTheme!,
              icon: theme.brightness == Brightness.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            ),
          ],
        ],
      ),
    );
  }
}

/// Keeps the reference header silhouette when no app theme callback is given.
class _ProfileTopBarDecoration extends StatelessWidget {
  const _ProfileTopBarDecoration();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ExcludeSemantics(
      child: SizedBox(
        width: AppSpacing.topBarActionSize,
        height: AppSpacing.topBarActionSize,
        child: Center(
          child: Icon(Icons.dark_mode_outlined, size: AppSpacing.topBarActionIconSize, color: theme.colorScheme.onSurface),
        ),
      ),
    );
  }
}

class _ProfileTopBarAction extends StatelessWidget {
  const _ProfileTopBarAction({required this.tooltip, required this.onPressed, required this.icon, super.key});

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      button: true,
      label: tooltip,
      onTap: onPressed,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.transparent,
          child: InkResponse(
            onTap: onPressed,
            excludeFromSemantics: true,
            radius: AppSpacing.topBarActionSize / 2,
            child: SizedBox(
              width: AppSpacing.topBarActionSize,
              height: AppSpacing.topBarActionSize,
              child: Center(
                child: Icon(icon, size: AppSpacing.topBarActionIconSize, color: theme.colorScheme.onSurface),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileSectionTitle extends StatelessWidget {
  const _ProfileSectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      header: true,
      child: Text(
        title,
        style: theme.textTheme.titleMedium?.copyWith(color: tokens.mutedText, fontWeight: FontWeight.w500, height: 1.15),
      ),
    );
  }
}

class _ProfileActionFeedback extends StatelessWidget {
  const _ProfileActionFeedback({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.accentSoft,
          borderRadius: AppRadii.control,
          border: Border.all(color: tokens.accent),
        ),
        child: Padding(
          padding: const EdgeInsets.only(
            left: AppSpacing.regular,
            top: AppSpacing.compact,
            right: AppSpacing.compact,
            bottom: AppSpacing.compact,
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.info_outline_rounded, color: tokens.accent),
              const SizedBox(width: AppSpacing.compact),
              Expanded(
                child: Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onPrimaryContainer)),
              ),
              IconButton(tooltip: '关闭提示', onPressed: onDismiss, icon: const Icon(Icons.close_rounded)),
            ],
          ),
        ),
      ),
    );
  }
}
