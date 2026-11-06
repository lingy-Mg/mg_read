part of 'profile_general_setting_page.dart';

/// 外观选项使用同一选择样式与可伸缩命中区；所有状态经显式回调写回设置。
class _AppearanceChoiceGroup extends StatelessWidget {
  const _AppearanceChoiceGroup({required this.keyPrefix, required this.value, required this.options, required this.onChanged, super.key});

  final String keyPrefix;
  final String value;
  final List<(String, String, IconData)> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: AppSpacing.compact),
          Expanded(
            child: Semantics(
              selected: value == options[i].$1,
              child: Material(
                color: value == options[i].$1 ? tokens.accentSoft : tokens.mutedSurface,
                shape: RoundedRectangleBorder(
                  borderRadius: AppRadii.detailControl,
                  side: BorderSide(color: value == options[i].$1 ? tokens.accent : tokens.divider),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: Key('$keyPrefix-${options[i].$1}'),
                  onTap: () => onChanged(options[i].$1),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.unit, vertical: AppSpacing.regular),
                    child: Column(
                      children: [
                        Icon(options[i].$3, color: value == options[i].$1 ? tokens.accent : tokens.mutedText),
                        const SizedBox(height: AppSpacing.compact),
                        Text(
                          options[i].$2,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: value == options[i].$1 ? tokens.accent : null,
                            fontWeight: value == options[i].$1 ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _AppearanceFieldLabel extends StatelessWidget {
  const _AppearanceFieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600));
}
