/// 已配对同步操作的策略判断与用户可见摘要。
part of 'device_sync_controller.dart';

String _summaryMessage(String label, PairedSyncRunSummary summary) {
  final changes = summary.receivedBooks + summary.receivedPlugins + summary.sentBooks + summary.sentPlugins;
  if (summary.developmentConflicts > 0) {
    return '$label 同步完成；${summary.developmentConflicts} 个开发书源存在双端修改，已保留两端现状';
  }
  if (changes == 0) return '$label 已是最新状态';
  return '$label 同步完成：接收 ${summary.receivedPlugins} 个插件、${summary.receivedBooks} 本书架更新；发送 ${summary.sentPlugins} 个插件、${summary.sentBooks} 本书架更新';
}

bool _operationAllowed(PairedDevice device, PairedSyncOperation operation) => switch (operation) {
  PairedSyncOperation.bidirectional => device.canReceive && device.canSend,
  PairedSyncOperation.pull => device.canReceive,
  PairedSyncOperation.push => device.canSend,
};
