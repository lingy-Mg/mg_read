import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/profile_view_data.dart';

/// A precise, bordered list of profile settings without default ListTile
/// spacing or typography.
class ProfileSettingsList extends StatelessWidget {
  /// Creates a vertically grouped settings list.
  const ProfileSettingsList({required this.items, required this.onItemPressed, super.key});

  final List<ProfileSettingsItemViewData> items;
  final ValueChanged<ProfileSettingsItemViewData> onItemPressed;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.profileList,
        border: Border.all(color: tokens.divider.withValues(alpha: 0.72)),
      ),
      child: ClipRRect(
        borderRadius: AppRadii.profileList,
        child: Column(
          key: const Key('profile-settings-list'),
          children: List<Widget>.generate(items.length, (int index) {
            final ProfileSettingsItemViewData item = items[index];
            return Column(
              children: <Widget>[
                ProfileSettingsRow(item: item, onPressed: () => onItemPressed(item)),
                if (index < items.length - 1)
                  Padding(
                    padding: const EdgeInsets.only(
                      left: AppSpacing.profileSettingsDividerStart,
                      right: AppSpacing.profileSettingsTrailingRight,
                    ),
                    child: Divider(
                      height: 1,
                      thickness: AppSpacing.profileStatsDividerThickness,
                      color: tokens.divider.withValues(alpha: 0.72),
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
  const ProfileSettingsRow({required this.item, required this.onPressed, super.key});

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
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.profileSettingsTrailingRight),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: AppSpacing.profileSettingsIconSlot,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Icon(_iconFor(item.icon), color: tokens.warning, size: AppSpacing.profileSettingsIconSize),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.profileSettingsIconTextGap),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.15),
                        ),
                        const SizedBox(height: AppSpacing.unit / 2),
                        Text(
                          item.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText, fontWeight: FontWeight.w400, height: 1.25),
                        ),
                      ],
                    ),
                  ),
                  if (item.trailingLabel != null) ...<Widget>[
                    const SizedBox(width: AppSpacing.compact),
                    Text(
                      item.trailingLabel!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: item.isAccentTrailingLabel ? tokens.warning : tokens.mutedText,
                        fontWeight: FontWeight.w400,
                        height: 1.1,
                      ),
                    ),
                  ],
                  const SizedBox(width: AppSpacing.compact),
                  Icon(Icons.chevron_right_rounded, color: tokens.mutedText, size: AppSpacing.profileChevronSize),
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
      ProfileSettingsIcon.importExport => Icons.import_export_rounded,
      ProfileSettingsIcon.backup => Icons.cloud_upload_outlined,
      ProfileSettingsIcon.diagnostics => Icons.bug_report_outlined,
      ProfileSettingsIcon.about => Icons.info_outline_rounded,
      ProfileSettingsIcon.feedback => Icons.edit_note_outlined,
    };
  }
}
