import 'package:mg_read/core/errors/app_error.dart';

/// Centralized Simplified Chinese copy for the MgRead host application.
abstract final class AppStrings {
  static const String applicationName = 'MgRead';
  static const String libraryTitle = '首页';
  static const String libraryIconLabel = '书架';
  static const String libraryLoadingLabel = '正在加载书架';
  static const String libraryRefreshingLabel = '正在刷新书架';
  static const String libraryEmptyTitle = '书架还没有内容';
  static const String libraryEmptyDescription = '插件、真实书源和本地持久化将在后续交付包接入。';
  static const String libraryRetainedDataDescription = '已保留上次成功加载的数据。';
  static const String retryLabel = '重试';
  static const String previewModeLabel = '界面预览';
  static const String previewModeDescription = '示例书籍仅用于展示首页，不代表已读取本地书架。';
  static const String continueReadingTitle = '继续阅读';
  static const String continueReadingLabel = '继续阅读';
  static const String readingHistoryLabel = '阅读记录';
  static const String recentUpdatesLabel = '最近更新';
  static const String shelfLabel = '书架';
  static const String filterAllLabel = '全部';
  static const String filterOngoingLabel = '连载';
  static const String filterCompletedLabel = '完结';
  static const String filterLocalLabel = '本地';
  static const String statusFilterLabel = '书籍状态筛选';
  static const String manageSourcesLabel = '管理我的书源';
  static const String manageSourcesActionLabel = '管理书源';
  static const String homeNavigationLabel = '首页';
  static const String searchNavigationLabel = '搜索';
  static const String discoverNavigationLabel = '发现';
  static const String profileNavigationLabel = '我的';
  static const String profileDisplayName = '书海行者';
  static const String profileEditLabel = '编辑资料';
  static const String profileVipLabel = 'VIP';
  static const String profileMotto = '书山有路勤为径，阅读点亮生活。';
  static const String profileReadingDurationLabel = '阅读时长';
  static const String profileReadingDurationValue = '126 小时';
  static const String profileReadBooksLabel = '阅读书籍';
  static const String profileReadBooksValue = '48 本';
  static const String profileShelfCollectionLabel = '书架收藏';
  static const String profileShelfCollectionValue = '136 本';
  static const String profileCloudSyncNormalLabel = '云端同步正常';
  static const String profileLastSyncLabel = '上次同步：刚刚';
  static const String profileSettingsManagementTitle = '设置与管理';
  static const String profileReadingSettingsTitle = '阅读设置';
  static const String profileReadingSettingsDescription = '字体、排版、翻页等';
  static const String profileSourceManagementTitle = '书源管理';
  static const String profileSourceManagementDescription = '管理书源、导入与排序';
  static const String profileDownloadCacheTitle = '下载与缓存';
  static const String profileDownloadCacheDescription = '已用 512MB / 共 5GB';
  static const String profileThemeAppearanceTitle = '主题与外观';
  static const String profileThemeAppearanceDescription = '跟随系统 / 暖光主题';
  static const String profilePrivacyPermissionsTitle = '隐私与权限';
  static const String profilePrivacyPermissionsDescription = '权限管理与隐私设置';
  static const String profileDataBackupTitle = '数据备份与同步';
  static const String profileDataBackupDescription = '云端备份，跨设备同步';
  static const String profileDataBackupValue = '已开启';
  static const String profileClearCacheTitle = '清理缓存';
  static const String profileClearCacheDescription = '释放存储空间';
  static const String profileClearCacheValue = '512MB';
  static const String profileAboutSectionTitle = '关于与其他';
  static const String profileAboutTitle = '关于我们';
  static const String profileAboutDescription = '版本 1.2.0';
  static const String profileFeedbackTitle = '意见反馈';
  static const String profileFeedbackDescription = '告诉我们您的想法';
  static const String profileNotificationsLabel = '通知';
  static const String profileAvatarLabel = '书海行者的头像';
  static const String searchActionLabel = '搜索书籍';
  static const String switchToDarkThemeLabel = '切换至深色模式';
  static const String switchToLightThemeLabel = '切换至浅色模式';
  static const String moreActionsLabel = '更多操作';
  static const String bookMoreActionsLabel = '书籍更多操作';
  static const String noReadingProgressTitle = '从书架开始阅读';
  static const String noReadingProgressDescription = '阅读进度接入本地资料后会显示在这里。';
  static const String noMatchingBooksLabel = '没有符合当前筛选条件的书籍';
  static const String unreadUpdateLabel = '有更新';
  static const String actionUnavailableMessage = '此操作尚未接入真实数据，可由后续功能替换。';
  static const String dismissLabel = '关闭提示';
  static const String readerRouteTitle = '阅读会话尚未就绪';
  static const String readerRouteDescription =
      '此路由只保存稳定书籍 ID。后续由应用用例解析数据源和状态存储后再打开阅读器。';
  static const String routeNotFoundTitle = '页面不存在';
  static const String routeNotFoundDescription = '请求的页面无法打开，请返回书架后重试。';

  /// Returns an accessible reading-progress description.
  static String readingProgressLabel(int percentage) => '阅读进度 $percentage%';

  /// Returns a label for a neutral, locally drawn cover representation.
  static String bookCoverLabel(String title) => '$title 的封面占位图';

  /// Returns a concise, accessible description for a shared book-list row.
  static String bookListItemLabel({
    required String title,
    String? subtitle,
    String? activityLabel,
    bool hasAttentionIndicator = false,
  }) {
    final List<String> parts = <String>[title];
    if (subtitle != null && subtitle.isNotEmpty) {
      parts.add(subtitle);
    }
    if (activityLabel != null && activityLabel.isNotEmpty) {
      parts.add(activityLabel);
    }
    if (hasAttentionIndicator) {
      parts.add(unreadUpdateLabel);
    }
    return parts.join('，');
  }

  /// Returns the available-source count without treating it as live data.
  static String availableSourcesLabel(int sourceCount) => '$sourceCount 个可用书源';

  /// Returns copy based only on a normalized, safe error category.
  static String errorTitle(AppError error) {
    return switch (error.category) {
      AppErrorCategory.retryableTemporary => '暂时无法完成请求',
      AppErrorCategory.runtimeUnavailable => '运行环境不可用',
      AppErrorCategory.pluginUnavailable => '插件不可用',
      AppErrorCategory.interactionRequired => '需要用户交互',
      AppErrorCategory.contentUnavailable => '内容不可用',
      AppErrorCategory.storagePressure => '存储空间不足',
      AppErrorCategory.incompatible => '版本不兼容',
      AppErrorCategory.cancelled => '操作已取消',
      AppErrorCategory.unknownSafe => '无法安全完成请求',
    };
  }

  /// Returns safe, actionable copy without exposing an upstream exception.
  static String errorDescription(AppError error) {
    return switch (error.category) {
      AppErrorCategory.retryableTemporary => '请稍后重试。',
      AppErrorCategory.runtimeUnavailable => '请重启应用后重试；诊断入口将在后续交付包提供。',
      AppErrorCategory.pluginUnavailable => '请在后续插件管理功能中检查插件状态。',
      AppErrorCategory.interactionRequired => '当前版本尚未提供所需的交互能力。',
      AppErrorCategory.contentUnavailable => '请返回上一层并选择其他可用内容。',
      AppErrorCategory.storagePressure => '请释放可再生缓存或存储空间后重试。',
      AppErrorCategory.incompatible => '请更新应用或恢复兼容的插件版本。',
      AppErrorCategory.cancelled => '当前页面保持最近的稳定状态。',
      AppErrorCategory.unknownSafe => '请稍后重试；如问题持续出现，请在诊断页面查看稳定错误码。',
    };
  }
}
