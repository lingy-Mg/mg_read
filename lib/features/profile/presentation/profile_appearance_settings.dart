part of 'profile_general_setting_page.dart';

/// 外观配置分别展示在显示模式、主题配色与书架样式页面；不在分类页展开控件。
/// 主题预览随配色即时刷新，书架开关不影响阅读器内部主题。
class _AppearanceSettings extends StatelessWidget {
  const _AppearanceSettings({required this.settings, required this.settingId});

  final AppSettingsManager settings;
  final String settingId;

  @override
  Widget build(BuildContext context) {
    final light = AppThemeColor.fromId(settings.get(AppSettingKeys.themeColor));
    final dark = AppDarkThemeColor.fromId(settings.get(AppSettingKeys.darkThemeColor));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (settingId == 'display-settings') ...[
          _AppearanceSection(
            icon: Icons.brightness_6_outlined,
            title: '界面明暗',
            description: '选择明暗，或跟随系统自动切换',
            child: _AppearanceChoiceGroup(
              key: const Key('appearance-theme-mode'),
              keyPrefix: 'appearance-theme-mode',
              value: settings.get(AppSettingKeys.themeMode),
              options: const [
                ('system', '跟随系统', Icons.brightness_auto_outlined),
                ('light', '日间', Icons.light_mode_outlined),
                ('dark', '夜间', Icons.dark_mode_outlined),
              ],
              onChanged: (value) => settings.set(AppSettingKeys.themeMode, value),
            ),
          ),
          const SizedBox(height: AppSpacing.section),
          const ProfileTvModeCard(),
        ],
        if (settingId == 'theme-colors') ...[
          const _AppearanceSectionHeading(icon: Icons.palette_outlined, title: '日间与夜间配色', description: '两套颜色分别保存，点选即可预览'),
          const SizedBox(height: AppSpacing.regular),
          _AppearancePreviewCard(
            lightColor: light,
            darkColor: dark,
            onLightChanged: (value) => settings.set(AppSettingKeys.themeColor, value.id),
            onDarkChanged: (value) => settings.set(AppSettingKeys.darkThemeColor, value.id),
          ),
        ],
        if (settingId == 'bookshelf-settings')
          _AppearanceSection(
            icon: Icons.auto_stories_outlined,
            title: '布局与封面',
            description: '调整首页的浏览方式和封面信息',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _AppearanceFieldLabel('浏览布局'),
                const SizedBox(height: AppSpacing.compact),
                _AppearanceChoiceGroup(
                  key: const Key('appearance-layout-mode'),
                  keyPrefix: 'appearance-layout-mode',
                  value: settings.get(AppSettingKeys.homeLayoutMode),
                  options: const [('list', '列表', Icons.view_agenda_outlined), ('card', '卡片', Icons.grid_view_rounded)],
                  onChanged: (value) => settings.set(AppSettingKeys.homeLayoutMode, value),
                ),
                const SizedBox(height: AppSpacing.comfortable),
                const _AppearanceFieldLabel('封面信息位置'),
                const SizedBox(height: AppSpacing.unit),
                Text('用于卡片布局', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppThemeTokens.of(context).mutedText)),
                const SizedBox(height: AppSpacing.compact),
                _AppearanceChoiceGroup(
                  key: const Key('appearance-cover-metadata-mode'),
                  keyPrefix: 'appearance-cover-metadata-mode',
                  value: settings.get(AppSettingKeys.homeCoverMetadataMode),
                  options: const [('belowCover', '封面下方', Icons.text_snippet_outlined), ('insideCover', '封面内叠加', Icons.movie_outlined)],
                  onChanged: (value) => settings.set(AppSettingKeys.homeCoverMetadataMode, value),
                ),
                const SizedBox(height: AppSpacing.compact),
                Divider(color: AppThemeTokens.of(context).divider),
                SwitchListTile.adaptive(
                  key: const Key('bookshelf-unread-badge'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('显示未读章节数'),
                  subtitle: const Text('在书架封面上显示未读数量'),
                  value: settings.get(AppSettingKeys.bookshelfUnreadBadgeEnabled),
                  onChanged: (value) => settings.set(AppSettingKeys.bookshelfUnreadBadgeEnabled, value),
                ),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.comfortable),
        const _InlineNotice(icon: Icons.menu_book_outlined, message: '此处设置应用界面与书架；阅读器内的字体、背景和主题请在阅读时调整。'),
      ],
    );
  }
}

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection({required this.icon, required this.title, required this.description, required this.child});

  final IconData icon;
  final String title;
  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Material(
      color: tokens.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadii.detailCard,
        side: BorderSide(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.comfortable),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _AppearanceSectionHeading(icon: icon, title: title, description: description),
            const SizedBox(height: AppSpacing.comfortable),
            child,
          ],
        ),
      ),
    );
  }
}

class _AppearanceSectionHeading extends StatelessWidget {
  const _AppearanceSectionHeading({required this.icon, required this.title, required this.description});

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.unit),
          child: Icon(icon, size: 22, color: tokens.accent),
        ),
        const SizedBox(width: AppSpacing.regular),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: AppSpacing.unit),
              Text(description, style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
            ],
          ),
        ),
      ],
    );
  }
}
