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

String _syncOperationLabel(PairedDevice device, PairedSyncOperation operation) => switch (operation) {
  PairedSyncOperation.bidirectional => '正在与 ${device.label} 双向同步',
  PairedSyncOperation.pull => '正在从 ${device.label} 拉取',
  PairedSyncOperation.push => '正在向 ${device.label} 推送',
};

String _syncScope(PairedDevice device) {
  if (device.syncBookshelf && device.syncPlugins) return '书架、阅读进度和插件';
  if (device.syncBookshelf) return '书架和阅读进度';
  if (device.syncPlugins) return '插件';
  return '同步内容';
}

String _syncProgressDetail(PairedDevice device, String stage) {
  final scope = _syncScope(device);
  return switch (stage) {
    'wake_send' => '正在请求另一台设备建立连接',
    'wake_wait' => '正在等待另一台设备响应',
    'identity' => '正在验证配对信息',
    'connect' => '正在建立安全连接',
    'request' => '正在协商同步方向',
    'local_manifest' => '正在整理本机的$scope',
    'manifest_exchange' => '正在交换双方的同步清单',
    'import_plan' =>
      device.syncBookshelf && device.syncPlugins
          ? '正在比较书架进度和插件版本'
          : device.syncBookshelf
          ? '正在比较阅读进度'
          : device.syncPlugins
          ? '正在比较插件版本'
          : '正在确认同步内容',
    'selection_exchange' => '正在确认需要同步的内容',
    'receive_payload' => '正在接收$scope',
    'send_payload' => '正在发送$scope',
    'complete' => '正在确认双方已完成同步',
    'result_persist' => '正在保存同步结果',
    _ => '正在处理同步内容',
  };
}
