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

String _transportFailureMessage(PairedDevice device, String code, {required bool automatic}) {
  final retry = automatic ? '，稍后会自动重试' : '';
  return switch (code) {
    'lan_sync_connect_failed' when device.platform == PairedDevicePlatform.windows =>
      '无法连接 ${device.label}；请确认 Windows 防火墙已允许 MgRead 使用专用网络$retry',
    'lan_sync_connect_failed' => '无法连接 ${device.label}，请确认两台设备仍在同一局域网$retry',
    'lan_sync_peer_busy' => '${device.label} 正在执行另一次同步，请稍后重试',
    'lan_sync_peer_not_paired' || 'lan_sync_handshake_invalid' => '与 ${device.label} 的配对信息已不一致，请解除后重新配对',
    _ => '与 ${device.label} 同步失败$retry',
  };
}
