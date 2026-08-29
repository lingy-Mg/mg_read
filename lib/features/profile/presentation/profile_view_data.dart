import 'package:flutter/foundation.dart';

import 'package:mg_read/features/profile/domain/profile_reading_stats.dart';

/// Immutable, presentation-only data for the profile and settings screen.
///
/// This projection intentionally contains no account identity, Runtime Store,
/// account identity or cloud state. The current identity values remain a
/// disclosed visual fixture; the sync action itself is wired separately.
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

  /// Reuses the established summary-card design with local, non-account data.
  ProfileViewData withReadingStats(ProfileReadingStats readingStats) {
    return ProfileViewData(
      displayName: displayName,
      motto: motto,
      stats: <ProfileStatViewData>[
        ProfileStatViewData(label: '阅读时长', value: _readingDurationText(readingStats.totalReadingSeconds)),
        ProfileStatViewData(label: '阅读书籍', value: '${readingStats.readBookCount} 本'),
        ProfileStatViewData(label: '书架收藏', value: '${readingStats.shelfBookCount} 本'),
      ],
      syncLabel: syncLabel,
      lastSyncLabel: lastSyncLabel,
      settings: settings,
      about: about,
    );
  }
}

String _readingDurationText(int totalSeconds) {
  final duration = Duration(seconds: totalSeconds);
  if (duration.inHours > 0) return '${duration.inHours} 小时';
  return '${duration.inMinutes} 分钟';
}

/// One compact profile statistic shown in the summary card.
@immutable
final class ProfileStatViewData {
  /// Creates a text-only display statistic.
  const ProfileStatViewData({required this.label, required this.value}) : assert(label != ''), assert(value != '');

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
enum ProfileSettingsIcon { reading, sources, download, appearance, privacy, importExport, backup, diagnostics, about, feedback }

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
    syncLabel: '局域网同步',
    lastSyncLabel: '仅在你主动操作时传输',
    settings: <ProfileSettingsItemViewData>[
      ProfileSettingsItemViewData(id: 'reading-settings', title: '阅读设置', description: '字体、排版、翻页等', icon: ProfileSettingsIcon.reading),
      ProfileSettingsItemViewData(id: 'source-management', title: '数据源管理', description: '管理数据源与启用状态', icon: ProfileSettingsIcon.sources),
      ProfileSettingsItemViewData(id: 'downloads-cache', title: '缓存管理', description: '数据源缓存、封面缓存与存储用量', icon: ProfileSettingsIcon.download),
      ProfileSettingsItemViewData(id: 'theme-appearance', title: '主题与外观', description: '跟随系统 / 暖光主题', icon: ProfileSettingsIcon.appearance),
      ProfileSettingsItemViewData(id: 'privacy-permissions', title: '隐私与权限', description: '权限管理与隐私设置', icon: ProfileSettingsIcon.privacy),
      ProfileSettingsItemViewData(id: 'import-export', title: '导入导出', description: '选择数据源、书架与阅读进度', icon: ProfileSettingsIcon.importExport),
      ProfileSettingsItemViewData(id: 'data-backup', title: '局域网同步', description: '同一网络传输数据源、书架与进度', icon: ProfileSettingsIcon.backup),
    ],
    about: <ProfileSettingsItemViewData>[
      ProfileSettingsItemViewData(id: 'diagnostics', title: '调试日志', description: '查看应用与数据源运行日志', icon: ProfileSettingsIcon.diagnostics),
      ProfileSettingsItemViewData(id: 'about', title: '关于我们', description: '版本 1.2.0', icon: ProfileSettingsIcon.about),
      ProfileSettingsItemViewData(id: 'feedback', title: '意见反馈', description: '告诉我们您的想法', icon: ProfileSettingsIcon.feedback),
    ],
  );
}
