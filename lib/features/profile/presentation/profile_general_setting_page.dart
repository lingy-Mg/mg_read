/// “我的”中尚未单独拆分路由的通用设置页面。
///
/// 职责：
/// - 以真实能力提供阅读和外观设置，不展示“功能建设中”占位。
/// - 提供小说预加载、音频行为、视频解码/输出和书架布局设置。
/// - Android 界面渲染由视频设置面板交给原生启动偏好保存，重启后生效。
/// - 将阅读器内设置与应用级设置边界解释清楚。
/// - 阅读设置在 TV 宽屏分栏；外观按显示模式、主题配色和书架样式分组。
/// - 设置状态与持久化由 AppSettingsManager 持有；布局组件不另存设置副本。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/profile/presentation/profile_video_settings.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';

part 'profile_appearance_settings.dart';
part 'profile_appearance_options.dart';
part 'profile_appearance_theme_controls.dart';
part 'profile_reading_player_settings_components.dart';

class ProfileGeneralSettingPage extends ConsumerWidget {
  const ProfileGeneralSettingPage({required this.settingId, required this.onBackRequested, super.key});

  final String settingId;
  final VoidCallback onBackRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appSettingsStatusProvider);
    final AppSettingsManager settings = ref.watch(appSettingsProvider);
    final _GeneralSettingSpec spec = _specFor(settingId);
    final sections = switch (settingId) {
      'reading-settings' => _readingSections(context, settings),
      'theme-appearance' => <Widget>[_AppearanceSettings(settings: settings)],
      _ => _fallbackSections(context),
    };
    final tv = TvModeScope.isEnabled(context);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              AppSecondaryPageTopBar(
                title: spec.title,
                onBack: onBackRequested,
                headerKey: const Key('secondary-placeholder-top-bar'),
                backButtonKey: const Key('secondary-placeholder-back'),
              ),
              Expanded(
                child: tv && settingId != 'theme-appearance' && MediaQuery.sizeOf(context).width >= 1000
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 2,
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(0, 16, 28, 24),
                              child: _SettingHero(spec: spec),
                            ),
                          ),
                          Expanded(
                            flex: 5,
                            child: ListView(
                              key: Key('profile-general-setting-$settingId'),
                              padding: const EdgeInsets.fromLTRB(12, 16, 20, 32),
                              children: sections,
                            ),
                          ),
                        ],
                      )
                    : ListView(
                        key: Key('profile-general-setting-$settingId'),
                        padding: const EdgeInsets.fromLTRB(
                          AppDetailMetrics.horizontalPadding,
                          AppSpacing.regular,
                          AppDetailMetrics.horizontalPadding,
                          AppSpacing.section,
                        ),
                        children: <Widget>[
                          if (settingId != 'theme-appearance') ...<Widget>[
                            _SettingHero(spec: spec),
                            const SizedBox(height: AppSpacing.section),
                          ],
                          ...sections,
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _readingSections(BuildContext context, AppSettingsManager settings) => <Widget>[
    SwitchListTile.adaptive(
      key: const Key('source-auto-update-check'),
      contentPadding: EdgeInsets.zero,
      title: const Text('自动更新数据源'),
      subtitle: const Text('空闲时静默下载，下次启动生效'),
      value: settings.get(AppSettingKeys.sourceAutoUpdateCheckEnabled),
      onChanged: (value) => settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, value),
    ),
    const _SectionHeading(title: '小说阅读', description: '只保留影响章节加载的设置'),
    const SizedBox(height: AppSpacing.regular),
    SwitchListTile.adaptive(
      key: const Key('bookshelf-auto-catalog-refresh'),
      contentPadding: EdgeInsets.zero,
      title: const Text('自动检查新章节'),
      subtitle: const Text('打开书架或回到前台时只检查章节目录，不更新封面和书籍信息'),
      value: settings.get(AppSettingKeys.bookshelfCatalogAutoRefreshEnabled),
      onChanged: (bool value) => settings.set(AppSettingKeys.bookshelfCatalogAutoRefreshEnabled, value),
    ),
    _NovelPreloadChapterCountCard(
      value: settings.get(AppSettingKeys.novelPreloadChapterCount),
      onChanged: (int value) async {
        await settings.set(AppSettingKeys.novelPreloadChapterCount, value);
      },
    ),
    const SizedBox(height: AppSpacing.section),
    const _SectionHeading(title: '音频播放器', description: '选择退出行为和应用内迷你播放条样式'),
    const SizedBox(height: AppSpacing.regular),
    _AudioExitBehaviorCard(
      value: settings.get(AppSettingKeys.audioExitBehavior),
      onChanged: (String value) async {
        await settings.set(AppSettingKeys.audioExitBehavior, value);
      },
    ),
    const SizedBox(height: AppSpacing.regular),
    _AudioMiniPlayerStyleCard(
      value: settings.get(AppSettingKeys.audioMiniPlayerStyle),
      onChanged: (String value) async {
        await settings.set(AppSettingKeys.audioMiniPlayerStyle, value);
      },
    ),
    const SizedBox(height: AppSpacing.regular),
    _AudioRememberPositionCard(
      value: settings.get(AppSettingKeys.audioRememberPosition),
      onChanged: (bool value) => settings.set(AppSettingKeys.audioRememberPosition, value),
    ),
    const SizedBox(height: AppSpacing.section),
    const _SectionHeading(title: '视频播放器', description: '选择解码和输出方式；自动模式保留设备兼容策略'),
    const SizedBox(height: AppSpacing.regular),
    const ProfileVideoSettings(),
    const SizedBox(height: AppSpacing.regular),
    const _InlineNotice(icon: Icons.tune_rounded, message: '字体、主题、排版、翻页和评论入口，请打开书籍后在阅读器工具栏的“设置”中调整。它们不会在这里重复显示。'),
  ];

  List<Widget> _fallbackSections(BuildContext context) => const <Widget>[
    _InlineNotice(icon: Icons.info_outline_rounded, message: '当前页面没有可配置项目。'),
  ];
}

class _SettingHero extends StatelessWidget {
  const _SettingHero({required this.spec});

  final _GeneralSettingSpec spec;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.featureSurface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.accent.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.comfortable),
        child: Row(
          children: <Widget>[
            SizedBox.square(
              dimension: 48,
              child: DecoratedBox(
                decoration: BoxDecoration(color: tokens.accent, borderRadius: AppRadii.detailControl),
                child: Icon(spec.icon, color: theme.colorScheme.onPrimary, size: 25),
              ),
            ),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(spec.heroTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: AppSpacing.unit),
                  Text(spec.description, style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.compact),
            DecoratedBox(
              decoration: BoxDecoration(color: tokens.surface, borderRadius: AppRadii.pill),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.regular, vertical: AppSpacing.compact),
                child: Text(
                  spec.badge,
                  style: theme.textTheme.bodySmall?.copyWith(color: tokens.accent, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.description});
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.unit),
        Text(description, style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
      ],
    );
  }
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

class _GeneralSettingSpec {
  const _GeneralSettingSpec({
    required this.title,
    required this.heroTitle,
    required this.description,
    required this.badge,
    required this.icon,
  });
  final String title;
  final String heroTitle;
  final String description;
  final String badge;
  final IconData icon;
}

_GeneralSettingSpec _specFor(String settingId) => switch (settingId) {
  'reading-settings' => const _GeneralSettingSpec(
    title: '阅读器与播放器',
    heroTitle: '阅读器与播放器',
    description: '管理章节预加载和离开音频播放器时的行为',
    badge: '直接生效',
    icon: Icons.menu_book_rounded,
  ),
  'theme-appearance' => const _GeneralSettingSpec(
    title: '主题与外观',
    heroTitle: '主题与外观',
    description: '显示模式、主题配色与书架样式',
    badge: '即时生效',
    icon: Icons.palette_outlined,
  ),
  _ => const _GeneralSettingSpec(title: '设置', heroTitle: '设置', description: '当前没有可配置项目', badge: 'MgRead', icon: Icons.settings_outlined),
};
