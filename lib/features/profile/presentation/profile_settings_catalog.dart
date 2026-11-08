/// 设置导航目录：主页只展示分类，分类页再进入各自的设置或工具。
/// 这里只投影不可变文案和平台可用入口；路由及持久化仍由应用层持有。
library;

import 'dart:io';

import 'package:mg_read/features/profile/presentation/profile_view_data.dart';

abstract final class ProfileSettingsCatalog {
  static const categories = <ProfileSettingsItemViewData>[
    ProfileSettingsItemViewData(id: 'reading-settings', title: '阅读与播放', description: '小说阅读、音频与视频播放器', icon: ProfileSettingsIcon.reading),
    ProfileSettingsItemViewData(
      id: 'theme-appearance',
      title: '主题与外观',
      description: '显示模式、主题配色与书架样式',
      icon: ProfileSettingsIcon.appearance,
    ),
    ProfileSettingsItemViewData(id: 'data-storage', title: '数据与存储', description: '数据源、缓存与导入导出', icon: ProfileSettingsIcon.download),
    ProfileSettingsItemViewData(id: 'connection-devices', title: '连接与设备', description: '局域网同步与设备配对', icon: ProfileSettingsIcon.backup),
    ProfileSettingsItemViewData(
      id: 'advanced-settings',
      title: '高级设置',
      description: '网络代理、运行时与问题诊断',
      icon: ProfileSettingsIcon.diagnostics,
    ),
  ];

  static const _reading = <ProfileSettingsItemViewData>[
    ProfileSettingsItemViewData(id: 'novel-settings', title: '小说阅读', description: '自动检查新章节、章节预加载', icon: ProfileSettingsIcon.reading),
    ProfileSettingsItemViewData(id: 'audio-settings', title: '音频播放器', description: '退出行为、迷你播放条与播放进度', icon: ProfileSettingsIcon.audio),
    ProfileSettingsItemViewData(id: 'video-settings', title: '视频播放器', description: '解码、输出与播放选项', icon: ProfileSettingsIcon.video),
  ];

  static const _appearance = <ProfileSettingsItemViewData>[
    ProfileSettingsItemViewData(
      id: 'display-settings',
      title: '显示模式',
      description: '跟随系统、日间、夜间与 TV 模式',
      icon: ProfileSettingsIcon.appearance,
    ),
    ProfileSettingsItemViewData(id: 'theme-colors', title: '主题配色', description: '分别设置日间与夜间的界面颜色', icon: ProfileSettingsIcon.appearance),
    ProfileSettingsItemViewData(id: 'bookshelf-settings', title: '书架样式', description: '浏览布局、封面信息与未读标记', icon: ProfileSettingsIcon.reading),
  ];

  static const _sourceUpdates = ProfileSettingsItemViewData(
    id: 'source-updates',
    title: '数据源更新',
    description: '自动下载数据源更新，下次启动生效',
    icon: ProfileSettingsIcon.sources,
  );

  static ProfileSettingsItemViewData? find(String id) {
    for (final item in [...categories, ..._reading, ..._appearance, _sourceUpdates]) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// 返回 null 表示具体设置页；空列表仍代表一个有效分类。
  static List<ProfileSettingsItemViewData>? children(String id) {
    final data = ProfileFixtures.preview;
    List<ProfileSettingsItemViewData> select(Set<String> ids) => data.settings.where((item) => ids.contains(item.id)).toList();
    return switch (id) {
      'reading-settings' => _reading,
      'theme-appearance' => _appearance,
      'data-storage' => [
        ...select({'source-management'}),
        _sourceUpdates,
        ...select({'downloads-cache', 'import-export'}),
      ],
      'connection-devices' => select({'data-backup', 'tv-companion'}),
      'advanced-settings' => [
        ...select({'network-proxy'}),
        if ((Platform.isAndroid || Platform.isWindows || Platform.isMacOS) && !const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME'))
          ProfileSettingsItemViewData(
            id: 'node-runtime',
            title: Platform.isAndroid ? 'Node.js 运行时' : 'JavaScript 运行时',
            description: '切换运行时，重启后生效',
            icon: ProfileSettingsIcon.sources,
          ),
        ...data.about.where((item) => item.id == 'diagnostics'),
      ],
      _ => null,
    };
  }
}
