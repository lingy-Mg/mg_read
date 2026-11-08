/// 设置分类与具体配置页，分类只展示导航，具体页面只承载单一用途的控件。
/// 状态与持久化由 AppSettingsManager 持有；页面不保存设置副本、不在 build 中执行 IO。
/// 分类跳转由应用路由回调处理，单独预览时使用本地路由；返回始终退回上一层。
/// 阅读器内部字体、主题和排版仍由阅读器自己的设置面板管理。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/profile/presentation/profile_settings_catalog.dart';
import 'package:mg_read/features/profile/presentation/profile_video_settings.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_settings_list.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_tv_mode_card.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

part 'profile_appearance_settings.dart';
part 'profile_appearance_options.dart';
part 'profile_appearance_theme_controls.dart';
part 'profile_reading_player_settings_components.dart';

class ProfileGeneralSettingPage extends ConsumerWidget {
  const ProfileGeneralSettingPage({required this.settingId, required this.onBackRequested, this.onSettingRequested, super.key});

  final String settingId;
  final VoidCallback onBackRequested;
  final ValueChanged<String>? onSettingRequested;

  void _openSetting(BuildContext context, String id) {
    if (onSettingRequested case final open?) {
      open(id);
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => ProfileGeneralSettingPage(settingId: id, onBackRequested: () => Navigator.of(context).pop()),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appSettingsStatusProvider);
    final settings = ref.watch(appSettingsProvider);
    final spec = ProfileSettingsCatalog.find(settingId);
    final items = ProfileSettingsCatalog.children(settingId);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: [
              AppSecondaryPageTopBar(
                title: spec?.title ?? '设置',
                onBack: onBackRequested,
                headerKey: const Key('secondary-placeholder-top-bar'),
                backButtonKey: const Key('secondary-placeholder-back'),
              ),
              Expanded(
                child: ListView(
                  key: Key('profile-general-setting-$settingId'),
                  padding: const EdgeInsets.fromLTRB(
                    AppDetailMetrics.horizontalPadding,
                    AppSpacing.regular,
                    AppDetailMetrics.horizontalPadding,
                    AppSpacing.section,
                  ),
                  children: [
                    if (items != null) ...[
                      Text(spec?.description ?? '', style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: AppSpacing.comfortable),
                      ProfileSettingsList(items: items, onItemPressed: (item) => _openSetting(context, item.id)),
                    ] else
                      ..._sections(context, settings),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _sections(BuildContext context, AppSettingsManager settings) => switch (settingId) {
    'novel-settings' => [
      SwitchListTile.adaptive(
        key: const Key('bookshelf-auto-catalog-refresh'),
        contentPadding: EdgeInsets.zero,
        title: const Text('自动检查新章节'),
        subtitle: const Text('打开书架或回到前台时只检查章节目录，不更新封面和书籍信息'),
        value: settings.get(AppSettingKeys.bookshelfCatalogAutoRefreshEnabled),
        onChanged: (value) => settings.set(AppSettingKeys.bookshelfCatalogAutoRefreshEnabled, value),
      ),
      const SizedBox(height: AppSpacing.regular),
      _NovelPreloadChapterCountCard(
        value: settings.get(AppSettingKeys.novelPreloadChapterCount),
        onChanged: (value) => settings.set(AppSettingKeys.novelPreloadChapterCount, value),
      ),
      const SizedBox(height: AppSpacing.comfortable),
      const _InlineNotice(icon: Icons.tune_rounded, message: '字体、背景、排版与翻页方式，请在阅读时打开工具栏中的“设置”调整。'),
    ],
    'audio-settings' => [
      Text('退出播放器时', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: AppSpacing.regular),
      _AudioExitBehaviorCard(
        value: settings.get(AppSettingKeys.audioExitBehavior),
        onChanged: (value) => settings.set(AppSettingKeys.audioExitBehavior, value),
      ),
      const SizedBox(height: AppSpacing.section),
      Text('迷你播放条', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: AppSpacing.regular),
      _AudioMiniPlayerStyleCard(
        value: settings.get(AppSettingKeys.audioMiniPlayerStyle),
        onChanged: (value) => settings.set(AppSettingKeys.audioMiniPlayerStyle, value),
      ),
      const SizedBox(height: AppSpacing.regular),
      _AudioRememberPositionCard(
        value: settings.get(AppSettingKeys.audioRememberPosition),
        onChanged: (value) => settings.set(AppSettingKeys.audioRememberPosition, value),
      ),
    ],
    'video-settings' => [const ProfileVideoSettings()],
    'display-settings' || 'theme-colors' || 'bookshelf-settings' => [_AppearanceSettings(settings: settings, settingId: settingId)],
    'source-updates' => [
      SwitchListTile.adaptive(
        key: const Key('source-auto-update-check'),
        contentPadding: EdgeInsets.zero,
        title: const Text('自动更新数据源'),
        subtitle: const Text('空闲时静默下载，下次启动生效'),
        value: settings.get(AppSettingKeys.sourceAutoUpdateCheckEnabled),
        onChanged: (value) => settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, value),
      ),
    ],
    _ => [const _InlineNotice(icon: Icons.info_outline_rounded, message: '当前页面没有可配置项目。')],
  };
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: tokens.mutedSurface, borderRadius: AppRadii.detailControl),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, size: 18, color: tokens.mutedText),
            const SizedBox(width: AppSpacing.compact),
            Expanded(
              child: Text(message, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
            ),
          ],
        ),
      ),
    );
  }
}
