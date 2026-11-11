part of 'profile_general_setting_page.dart';

/// 日夜配色各自整合预览和色板；宽屏并排，窄屏或大字号上下排列。
/// 预览只消费 AppTheme 的真实语义颜色，不创建新的配色规则或持久化状态。
class _AppearancePreviewCard extends StatelessWidget {
  const _AppearancePreviewCard({
    required this.lightColor,
    required this.darkColor,
    required this.onLightChanged,
    required this.onDarkChanged,
  });

  final AppThemeColor lightColor;
  final AppDarkThemeColor darkColor;
  final ValueChanged<AppThemeColor> onLightChanged;
  final ValueChanged<AppDarkThemeColor> onDarkChanged;

  @override
  Widget build(BuildContext context) {
    final day = _ThemePaletteCard(
      key: const Key('appearance-theme-color'),
      title: '日间配色',
      icon: Icons.light_mode_outlined,
      selectedId: lightColor.id,
      selectedLabel: lightColor.label,
      preview: AppTheme.light(color: lightColor),
      keyPrefix: 'appearance-theme-color',
      colors: [for (final color in AppThemeColor.values) (color.id, color.label, color.accent)],
      onChanged: (id) => onLightChanged(AppThemeColor.fromId(id)),
    );
    final night = _ThemePaletteCard(
      key: const Key('appearance-dark-theme-color'),
      title: '夜间配色',
      icon: Icons.dark_mode_outlined,
      selectedId: darkColor.id,
      selectedLabel: darkColor.label,
      preview: AppTheme.dark(color: darkColor),
      keyPrefix: 'appearance-dark-theme-color',
      colors: [for (final color in AppDarkThemeColor.values) (color.id, color.label, color.accent)],
      onChanged: (id) => onDarkChanged(AppDarkThemeColor.fromId(id)),
    );
    return LayoutBuilder(
      key: const Key('appearance-settings-preview'),
      builder: (context, constraints) {
        if (constraints.maxWidth >= AppSpacing.compactLayoutBreakpoint && MediaQuery.textScalerOf(context).scale(1) <= 1.3) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: day),
              const SizedBox(width: AppSpacing.comfortable),
              Expanded(child: night),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            day,
            const SizedBox(height: AppSpacing.regular),
            night,
          ],
        );
      },
    );
  }
}

class _ThemePaletteCard extends StatelessWidget {
  const _ThemePaletteCard({
    required this.title,
    required this.icon,
    required this.selectedId,
    required this.selectedLabel,
    required this.preview,
    required this.keyPrefix,
    required this.colors,
    required this.onChanged,
    super.key,
  });

  final String title;
  final IconData icon;
  final String selectedId;
  final String selectedLabel;
  final ThemeData preview;
  final String keyPrefix;
  final List<(String, String, Color)> colors;
  final ValueChanged<String> onChanged;

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
            Row(
              children: [
                Icon(icon, color: tokens.mutedText, size: 18),
                const SizedBox(width: AppSpacing.compact),
                Expanded(child: _AppearanceFieldLabel(title)),
                const SizedBox(width: AppSpacing.compact),
                Flexible(
                  child: Text(selectedLabel, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.regular),
            AnimatedTheme(
              duration: AppMotion.effectiveDuration(context, AppMotion.themeTransition),
              curve: AppMotion.standardCurve,
              data: preview,
              child: _ThemeMiniature(key: Key('$keyPrefix-preview')),
            ),
            const SizedBox(height: AppSpacing.regular),
            LayoutBuilder(
              builder: (context, constraints) {
                final minWidth = MediaQuery.textScalerOf(context).scale(13) * 3 + AppSpacing.regular;
                final count = ((constraints.maxWidth + AppSpacing.unit) / (minWidth + AppSpacing.unit)).floor().clamp(1, colors.length);
                final width = (constraints.maxWidth - (count - 1) * AppSpacing.unit) / count;
                return Wrap(
                  spacing: AppSpacing.unit,
                  runSpacing: AppSpacing.compact,
                  children: [
                    for (final (id, label, color) in colors)
                      SizedBox(
                        width: width,
                        child: Semantics(
                          selected: selectedId == id,
                          child: InkWell(
                            key: Key('$keyPrefix-$id'),
                            borderRadius: AppRadii.detailControl,
                            onTap: () => onChanged(id),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: AppSpacing.compact),
                              child: Column(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(AppSpacing.unit),
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(color: selectedId == id ? tokens.accent : Colors.transparent, width: 2),
                                    ),
                                    child: CircleAvatar(
                                      radius: 12,
                                      backgroundColor: color,
                                      child: selectedId == id
                                          ? Icon(
                                              Icons.check_rounded,
                                              size: 16,
                                              color: ThemeData.estimateBrightnessForColor(color) == Brightness.dark
                                                  ? Colors.white
                                                  : Colors.black,
                                            )
                                          : null,
                                    ),
                                  ),
                                  const SizedBox(height: AppSpacing.unit),
                                  Text(label, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeMiniature extends StatelessWidget {
  const _ThemeMiniature({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.pageBackground,
          borderRadius: AppRadii.detailControl,
          border: Border.all(color: tokens.divider),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.regular),
          child: Row(
            children: [
              Container(
                width: AppSpacing.minimumTouchTarget,
                height: AppSpacing.minimumTouchTarget,
                decoration: BoxDecoration(color: tokens.accentSoft, borderRadius: AppRadii.detailControl),
                child: Icon(Icons.auto_stories_rounded, color: tokens.accent),
              ),
              const SizedBox(width: AppSpacing.regular),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '我的书架',
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: AppSpacing.unit),
                    Text('继续阅读', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.accent)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: tokens.mutedText),
            ],
          ),
        ),
      ),
    );
  }
}
