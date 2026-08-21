import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/profile_view_data.dart';

/// A precise, bordered list of profile settings without default ListTile
/// spacing or typography.
class ProfileSettingsList extends StatelessWidget {
  /// Creates a vertically grouped settings list.
  const ProfileSettingsList({
    required this.items,
    required this.onItemPressed,
    super.key,
  });

  final List<ProfileSettingsItemViewData> items;
  final ValueChanged<ProfileSettingsItemViewData> onItemPressed;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.profileList,
        border: Border.all(color: tokens.divider),
      ),
      child: ClipRRect(
        borderRadius: AppRadii.profileList,
        child: Column(
          key: const Key('profile-settings-list'),
          children: List<Widget>.generate(items.length, (int index) {
            final ProfileSettingsItemViewData item = items[index];
            return Column(
              children: <Widget>[
                ProfileSettingsRow(
                  item: item,
                  onPressed: () => onItemPressed(item),
                ),
                if (index < items.length - 1)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.regular,
                    ),
                    child: Divider(
                      height: 1,
                      thickness: 1,
                      color: tokens.divider,
                    ),
                  ),
              ],
            );
          }),
        ),
      ),
    );
  }
}

/// One fixed-height, touch-safe profile setting row.
class ProfileSettingsRow extends StatelessWidget {
  /// Creates a custom profile settings row.
  const ProfileSettingsRow({
    required this.item,
    required this.onPressed,
    super.key,
  });

  final ProfileSettingsItemViewData item;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final String accessibilityLabel = item.trailingLabel == null
        ? '${item.title}，${item.description}'
        : '${item.title}，${item.description}，${item.trailingLabel}';

    return Semantics(
      button: true,
      label: accessibilityLabel,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey<String>('profile-setting-${item.id}'),
          onTap: onPressed,
          child: SizedBox(
            height: AppSpacing.profileSettingsRowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.regular,
              ),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: AppSpacing.profileSettingsLeadingWidth,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Icon(
                        _iconFor(item.icon),
                        color: tokens.warning,
                        size: AppSpacing.profileSettingsIconSize,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                            height: 1.08,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.unit),
                        Text(
                          item.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: tokens.mutedText,
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                            height: 1.05,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (item.trailingLabel != null) ...<Widget>[
                    const SizedBox(width: AppSpacing.compact),
                    Text(
                      item.trailingLabel!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: item.isAccentTrailingLabel
                            ? tokens.warning
                            : tokens.mutedText,
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        height: 1.1,
                      ),
                    ),
                  ],
                  const SizedBox(width: AppSpacing.unit),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: tokens.mutedText,
                    size: 24,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  IconData _iconFor(ProfileSettingsIcon icon) {
    return switch (icon) {
      ProfileSettingsIcon.reading => Icons.calendar_month_outlined,
      ProfileSettingsIcon.sources => Icons.account_tree_outlined,
      ProfileSettingsIcon.download => Icons.file_download_outlined,
      ProfileSettingsIcon.appearance => Icons.palette_outlined,
      ProfileSettingsIcon.privacy => Icons.shield_outlined,
      ProfileSettingsIcon.backup => Icons.cloud_upload_outlined,
      ProfileSettingsIcon.clearCache => Icons.delete_outline_rounded,
      ProfileSettingsIcon.diagnostics => Icons.bug_report_outlined,
      ProfileSettingsIcon.about => Icons.info_outline_rounded,
      ProfileSettingsIcon.feedback => Icons.edit_note_outlined,
    };
  }
}
