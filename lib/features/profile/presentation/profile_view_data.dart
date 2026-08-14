import 'package:flutter/foundation.dart';

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
  diagnostics,
  about,
  feedback,
}

/// Clearly disclosed fixture data used while account and sync capabilities are
/// intentionally outside the current application milestone.
abstract final class ProfileFixtures {
  static const ProfileViewData preview = ProfileViewData(
    displayName: '书海行者',
    motto: '书山有路勤为径，阅读点亮生活。',
    stats: <ProfileStatViewData>[
      ProfileStatViewData(label: '阅读时长', value: '126 小时'),
      ProfileStatViewData(label: '阅读书籍', value: '48 本'),
      ProfileStatViewData(label: '书架收藏', value: '136 本'),
    ],
    syncLabel: '云端同步正常',
    lastSyncLabel: '上次同步：刚刚',
    settings: <ProfileSettingsItemViewData>[
      ProfileSettingsItemViewData(
        id: 'reading-settings',
        title: '阅读设置',
        description: '字体、排版、翻页等',
        icon: ProfileSettingsIcon.reading,
      ),
      ProfileSettingsItemViewData(
        id: 'source-management',
        title: '书源管理',
        description: '管理书源、导入与排序',
        icon: ProfileSettingsIcon.sources,
      ),
      ProfileSettingsItemViewData(
        id: 'downloads-cache',
        title: '下载与缓存',
        description: '已用 512MB / 共 5GB',
        icon: ProfileSettingsIcon.download,
      ),
      ProfileSettingsItemViewData(
        id: 'theme-appearance',
        title: '主题与外观',
        description: '跟随系统 / 暖光主题',
        icon: ProfileSettingsIcon.appearance,
      ),
      ProfileSettingsItemViewData(
        id: 'privacy-permissions',
        title: '隐私与权限',
        description: '权限管理与隐私设置',
        icon: ProfileSettingsIcon.privacy,
      ),
      ProfileSettingsItemViewData(
        id: 'data-backup',
        title: '数据备份与同步',
        description: '云端备份，跨设备同步',
        icon: ProfileSettingsIcon.backup,
        trailingLabel: '已开启',
        isAccentTrailingLabel: true,
      ),
      ProfileSettingsItemViewData(
        id: 'clear-cache',
        title: '清理缓存',
        description: '释放存储空间',
        icon: ProfileSettingsIcon.clearCache,
        trailingLabel: '512MB',
      ),
    ],
    about: <ProfileSettingsItemViewData>[
      ProfileSettingsItemViewData(
        id: 'diagnostics',
        title: '调试日志',
        description: '关键日志与限时详情捕获',
        icon: ProfileSettingsIcon.diagnostics,
      ),
      ProfileSettingsItemViewData(
        id: 'about',
        title: '关于我们',
        description: '版本 1.2.0',
        icon: ProfileSettingsIcon.about,
      ),
      ProfileSettingsItemViewData(
        id: 'feedback',
        title: '意见反馈',
        description: '告诉我们您的想法',
        icon: ProfileSettingsIcon.feedback,
      ),
    ],
  );
}
