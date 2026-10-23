/// “我的”中尚未单独拆分路由的通用设置页面。
///
/// 职责：
/// - 以真实能力提供阅读和外观设置，不展示“功能建设中”占位。
/// - 直接持久化小说预加载、音频续播/退出和书架布局设置。
/// - 将阅读器内设置与应用级设置边界解释清楚。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

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
                child: ListView(
                  key: Key('profile-general-setting-$settingId'),
                  padding: const EdgeInsets.fromLTRB(
                    AppDetailMetrics.horizontalPadding,
                    AppSpacing.regular,
                    AppDetailMetrics.horizontalPadding,
                    AppSpacing.section,
                  ),
                  children: <Widget>[
                    _SettingHero(spec: spec),
                    const SizedBox(height: AppSpacing.section),
                    ...switch (settingId) {
                      'reading-settings' => _readingSections(context, settings),
                      'theme-appearance' => _appearanceSections(context, settings),
                      _ => _fallbackSections(context),
                    },
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
    const _SectionHeading(title: '小说阅读', description: '只保留影响章节加载的设置'),
    const SizedBox(height: AppSpacing.regular),
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
    const SizedBox(height: AppSpacing.regular),
    const _InlineNotice(icon: Icons.tune_rounded, message: '字体、主题、排版、翻页和评论入口，请打开书籍后在阅读器工具栏的“设置”中调整。它们不会在这里重复显示。'),
  ];

  List<Widget> _appearanceSections(BuildContext context, AppSettingsManager settings) {
    final String layout = settings.get(AppSettingKeys.homeLayoutMode);
    final String coverMetadataMode = settings.get(AppSettingKeys.homeCoverMetadataMode);
    final String themeMode = settings.get(AppSettingKeys.themeMode);
    final AppThemeColor lightThemeColor = AppThemeColor.fromId(settings.get(AppSettingKeys.themeColor));
    final AppDarkThemeColor darkThemeColor = AppDarkThemeColor.fromId(settings.get(AppSettingKeys.darkThemeColor));
    return <Widget>[
      const _SectionHeading(title: '界面模式', description: '选择应用界面使用日间、夜间，或跟随系统设置'),
      const SizedBox(height: AppSpacing.regular),
      _ThemeModeCard(
        value: themeMode,
        onChanged: (String value) async {
          await settings.set(AppSettingKeys.themeMode, value);
        },
      ),
      const SizedBox(height: AppSpacing.section),
      const _SectionHeading(title: '日间主题色', description: '只影响应用日间界面；阅读器独立管理主题'),
      const SizedBox(height: AppSpacing.regular),
      _ThemeColorCard(
        value: lightThemeColor,
        onChanged: (AppThemeColor value) async {
          await settings.set(AppSettingKeys.themeColor, value.id);
        },
      ),
      const SizedBox(height: AppSpacing.regular),
      const _SectionHeading(title: '夜间主题色', description: '为夜间界面单独选择适合深色背景的配色'),
      const SizedBox(height: AppSpacing.regular),
      _DarkThemeColorCard(
        value: darkThemeColor,
        onChanged: (AppDarkThemeColor value) async {
          await settings.set(AppSettingKeys.darkThemeColor, value.id);
        },
      ),
      const SizedBox(height: AppSpacing.regular),
      _AppearancePreviewCard(lightColor: lightThemeColor, darkColor: darkThemeColor),
      const SizedBox(height: AppSpacing.section),
      const _SectionHeading(title: '书架布局', description: '选择书架首页的默认浏览方式'),
      const SizedBox(height: AppSpacing.regular),
      _LayoutModeCard(
        value: layout,
        onChanged: (String value) async {
          await settings.set(AppSettingKeys.homeLayoutMode, value);
        },
      ),
      const SizedBox(height: AppSpacing.regular),
      _CoverMetadataModeCard(
        value: coverMetadataMode,
        onChanged: (String value) async {
          await settings.set(AppSettingKeys.homeCoverMetadataMode, value);
        },
      ),
      const SizedBox(height: AppSpacing.comfortable),
      const _InlineNotice(icon: Icons.dark_mode_outlined, message: '日间和夜间主题色互不影响；阅读器内主题不受此处影响。'),
    ];
  }

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

class _ThemeModeCard extends StatefulWidget {
  const _ThemeModeCard({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_ThemeModeCard> createState() => _ThemeModeCardState();
}

class _ThemeModeCardState extends State<_ThemeModeCard> {
  late String _value = widget.value;

  @override
  void didUpdateWidget(covariant _ThemeModeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _value = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    const options = <(String, String, IconData)>[
      ('system', '跟随系统', Icons.brightness_auto_outlined),
      ('light', '日间', Icons.light_mode_outlined),
      ('dark', '夜间', Icons.dark_mode_outlined),
    ];
    return DecoratedBox(
      key: const Key('appearance-theme-mode'),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: Wrap(
          spacing: AppSpacing.compact,
          runSpacing: AppSpacing.compact,
          children: <Widget>[
            for (final (String value, String label, IconData icon) in options)
              ChoiceChip(
                key: Key('appearance-theme-mode-$value'),
                avatar: Icon(icon, size: 18),
                label: Text(label),
                selected: value == _value,
                onSelected: (_) {
                  setState(() => _value = value);
                  widget.onChanged(value);
                },
                selectedColor: tokens.accentSoft,
                side: BorderSide(color: value == _value ? tokens.accent : tokens.divider),
              ),
          ],
        ),
      ),
    );
  }
}

class _LayoutModeCard extends StatefulWidget {
  const _LayoutModeCard({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_LayoutModeCard> createState() => _LayoutModeCardState();
}

class _LayoutModeCardState extends State<_LayoutModeCard> {
  late String _value = widget.value;

  @override
  void didUpdateWidget(covariant _LayoutModeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _value = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: SegmentedButton<String>(
          key: const Key('appearance-layout-mode'),
          segments: const <ButtonSegment<String>>[
            ButtonSegment<String>(value: 'list', icon: Icon(Icons.view_agenda_outlined), label: Text('列表')),
            ButtonSegment<String>(value: 'card', icon: Icon(Icons.grid_view_rounded), label: Text('卡片')),
          ],
          selected: <String>{_value},
          showSelectedIcon: false,
          onSelectionChanged: (Set<String> selected) {
            final String value = selected.single;
            setState(() => _value = value);
            widget.onChanged(value);
          },
        ),
      ),
    );
  }
}

class _CoverMetadataModeCard extends StatefulWidget {
  const _CoverMetadataModeCard({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_CoverMetadataModeCard> createState() => _CoverMetadataModeCardState();
}

class _CoverMetadataModeCardState extends State<_CoverMetadataModeCard> {
  late String _value = widget.value;

  @override
  void didUpdateWidget(covariant _CoverMetadataModeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _value = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _SectionHeading(title: '封面信息', description: '选择卡片模式下标题和作者的显示位置'),
        const SizedBox(height: AppSpacing.regular),
        DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: AppRadii.detailCard,
            border: Border.all(color: tokens.divider),
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.regular),
            child: SegmentedButton<String>(
              key: const Key('appearance-cover-metadata-mode'),
              segments: const <ButtonSegment<String>>[
                ButtonSegment<String>(value: 'belowCover', icon: Icon(Icons.text_snippet_outlined), label: Text('封面下方')),
                ButtonSegment<String>(value: 'insideCover', icon: Icon(Icons.movie_outlined), label: Text('封面内叠加')),
              ],
              selected: <String>{_value},
              showSelectedIcon: false,
              onSelectionChanged: (Set<String> selected) {
                final String value = selected.single;
                setState(() => _value = value);
                widget.onChanged(value);
              },
            ),
          ),
        ),
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
    heroTitle: '暖光视觉',
    description: '统一、克制的浅色界面，保持各页面观感一致',
    badge: '当前主题',
    icon: Icons.palette_outlined,
  ),
  _ => const _GeneralSettingSpec(title: '设置', heroTitle: '设置', description: '当前没有可配置项目', badge: 'MgRead', icon: Icons.settings_outlined),
};
