import 'package:flutter/foundation.dart';

import 'package:mg_read/app/app_strings.dart';

/// Immutable, presentation-only data for the profile and settings screen.
///
/// This projection intentionally contains no account identity, Runtime Store,
/// cloud state, or persistence behavior. The current values are a disclosed
/// visual fixture until the corresponding Runtime capabilities exist.
@immutable
final class ProfileViewData {
  /// Creates one display-ready profile projection.
  const ProfileViewData({
    required this.displayName,
    required this.motto,
    required this.stats,
    required this.syncLabel,
    required this.lastSyncLabel,
    required this.settings,
    required this.about,
  }) : assert(displayName != ''),
       assert(motto != ''),
       assert(syncLabel != ''),
       assert(lastSyncLabel != '');

  final String displayName;
  final String motto;
  final List<ProfileStatViewData> stats;
  final String syncLabel;
  final String lastSyncLabel;
  final List<ProfileSettingsItemViewData> settings;
  final List<ProfileSettingsItemViewData> about;
}

/// One compact profile statistic shown in the summary card.
@immutable
final class ProfileStatViewData {
  /// Creates a text-only display statistic.
  const ProfileStatViewData({required this.label, required this.value})
    : assert(label != ''),
      assert(value != '');

  final String label;
  final String value;
}

/// A single settings or about row in the profile presentation.
@immutable
final class ProfileSettingsItemViewData {
  /// Creates one display-ready settings row.
  const ProfileSettingsItemViewData({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    this.trailingLabel,
    this.isAccentTrailingLabel = false,
  }) : assert(id != ''),
       assert(title != ''),
       assert(description != '');

  final String id;
  final String title;
  final String description;
  final ProfileSettingsIcon icon;
  final String? trailingLabel;
  final bool isAccentTrailingLabel;
}

/// Symbol choices that keep the profile fixture independent from Material UI.
enum ProfileSettingsIcon {
  reading,
  sources,
  download,
  appearance,
  privacy,
  backup,
  clearCache,
  about,
  feedback,
}

/// Clearly disclosed fixture data used while account and sync capabilities are
/// intentionally outside the current application milestone.
abstract final class ProfileFixtures {
  static const ProfileViewData preview = ProfileViewData(
    displayName: AppStrings.profileDisplayName,
    motto: AppStrings.profileMotto,
    stats: <ProfileStatViewData>[
      ProfileStatViewData(
        label: AppStrings.profileReadingDurationLabel,
        value: AppStrings.profileReadingDurationValue,
      ),
      ProfileStatViewData(
        label: AppStrings.profileReadBooksLabel,
        value: AppStrings.profileReadBooksValue,
      ),
      ProfileStatViewData(
        label: AppStrings.profileShelfCollectionLabel,
        value: AppStrings.profileShelfCollectionValue,
      ),
    ],
    syncLabel: AppStrings.profileCloudSyncNormalLabel,
    lastSyncLabel: AppStrings.profileLastSyncLabel,
    settings: <ProfileSettingsItemViewData>[
      ProfileSettingsItemViewData(
        id: 'reading-settings',
        title: AppStrings.profileReadingSettingsTitle,
        description: AppStrings.profileReadingSettingsDescription,
        icon: ProfileSettingsIcon.reading,
      ),
      ProfileSettingsItemViewData(
        id: 'source-management',
        title: AppStrings.profileSourceManagementTitle,
        description: AppStrings.profileSourceManagementDescription,
        icon: ProfileSettingsIcon.sources,
      ),
      ProfileSettingsItemViewData(
        id: 'downloads-cache',
        title: AppStrings.profileDownloadCacheTitle,
        description: AppStrings.profileDownloadCacheDescription,
        icon: ProfileSettingsIcon.download,
      ),
      ProfileSettingsItemViewData(
        id: 'theme-appearance',
        title: AppStrings.profileThemeAppearanceTitle,
        description: AppStrings.profileThemeAppearanceDescription,
        icon: ProfileSettingsIcon.appearance,
      ),
      ProfileSettingsItemViewData(
        id: 'privacy-permissions',
        title: AppStrings.profilePrivacyPermissionsTitle,
        description: AppStrings.profilePrivacyPermissionsDescription,
        icon: ProfileSettingsIcon.privacy,
      ),
      ProfileSettingsItemViewData(
        id: 'data-backup',
        title: AppStrings.profileDataBackupTitle,
        description: AppStrings.profileDataBackupDescription,
        icon: ProfileSettingsIcon.backup,
        trailingLabel: AppStrings.profileDataBackupValue,
        isAccentTrailingLabel: true,
      ),
      ProfileSettingsItemViewData(
        id: 'clear-cache',
        title: AppStrings.profileClearCacheTitle,
        description: AppStrings.profileClearCacheDescription,
        icon: ProfileSettingsIcon.clearCache,
        trailingLabel: AppStrings.profileClearCacheValue,
      ),
    ],
    about: <ProfileSettingsItemViewData>[
      ProfileSettingsItemViewData(
        id: 'about',
        title: AppStrings.profileAboutTitle,
        description: AppStrings.profileAboutDescription,
        icon: ProfileSettingsIcon.about,
      ),
      ProfileSettingsItemViewData(
        id: 'feedback',
        title: AppStrings.profileFeedbackTitle,
        description: AppStrings.profileFeedbackDescription,
        icon: ProfileSettingsIcon.feedback,
      ),
    ],
  );
}
