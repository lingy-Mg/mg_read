import 'package:mg_read/core/errors/app_error.dart';

/// Centralized Simplified Chinese copy for the MgRead host application.
abstract final class AppStrings {
  static const String applicationName = 'MgRead';
  static const String libraryTitle = '我的书架';
  static const String libraryIconLabel = '书架';
  static const String libraryLoadingLabel = '正在加载书架';
  static const String libraryRefreshingLabel = '正在刷新书架';
  static const String libraryEmptyTitle = '书架还没有内容';
  static const String libraryEmptyDescription = '插件、真实书源和本地持久化将在后续交付包接入。';
  static const String libraryRetainedDataDescription = '已保留上次成功加载的数据。';
  static const String retryLabel = '重试';
  static const String readerRouteTitle = '阅读会话尚未就绪';
  static const String readerRouteDescription =
      '此路由只保存稳定书籍 ID。后续由应用用例解析数据源和状态存储后再打开阅读器。';
  static const String routeNotFoundTitle = '页面不存在';
  static const String routeNotFoundDescription = '请求的页面无法打开，请返回书架后重试。';

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
