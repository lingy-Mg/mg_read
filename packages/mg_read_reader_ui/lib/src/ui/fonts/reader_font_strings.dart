abstract final class ReaderFontStrings {
  static const title = '字体管理';
  static const loading = '正在加载字体…';
  static const empty = '暂无可用字体';
  static const loadFailed = '字体列表加载失败';
  static const retry = '重试';
  static const download = '下载';
  static const installed = '已安装';
  static const inUse = '使用中';
  static const use = '使用';
  static const delete = '删除';
  static const downloading = '正在下载…';
  static const deleting = '正在删除…';
  static const installingFailed = '字体安装失败，请重试';
  static const deleteFailed = '字体删除失败，请重试';
  static const cachedBytesMissing = '安装完成后未找到字体文件';
  static const preview = '字体预览';
  static const close = '关闭';
  static const licenseUnknown = '未提供许可信息';

  static String version(String value) => '版本 $value';

  static String fileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
