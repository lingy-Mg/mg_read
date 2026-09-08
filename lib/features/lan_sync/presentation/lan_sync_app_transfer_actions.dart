/// 局域网同步页的 App 扫码与安装确认动作。
///
/// 保持弹窗上下文属于页面；传输和安装状态仍由两个应用控制器持有。
part of 'lan_sync_page.dart';

extension _LanSyncAppTransferActions on _LanSyncPageState {
  Future<void> _scanAndReceiveApp() async {
    final notifier = ref.read(appTransferControllerProvider.notifier);
    final payload = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => const LanSyncQrScannerPage(purpose: LanSyncQrScannerPurpose.appTransfer),
      ),
    );
    if (!mounted || payload == null) return;
    final offer = AppTransferQrPayload.decode(payload);
    if (offer == null) return;
    await notifier.connectOffer(offer);
    if (mounted && ref.read(appTransferControllerProvider).phase == AppTransferPhase.ready) {
      await _showTemporaryAppUpdatePrompt();
    }
  }

  Future<void> _showTemporaryAppUpdatePrompt() async {
    final appState = ref.read(appTransferControllerProvider);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(appState.remoteIsUpgrade ? '发现可升级版本' : '安装此 App 版本？'),
        content: AppVersionComparisonCard(local: appState.localVersion, remote: appState.offeredVersion, pairingCode: appState.pairingCode),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('暂不安装')),
          FilledButton(
            key: const Key('app-transfer-dialog-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(appState.remoteIsUpgrade ? '升级' : '强制安装'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await ref.read(appTransferControllerProvider.notifier).install(force: !appState.remoteIsUpgrade);
    }
  }

  Future<void> _confirmPairedAppUpdate(String deviceId, bool force) async {
    final deviceState = ref.read(deviceSyncControllerProvider);
    final offer = deviceState.appOffersByDeviceId[deviceId];
    final local = deviceState.localAppVersion;
    if (offer == null || local == null) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(force ? '强制安装此版本？' : '从在线设备升级 App？'),
        content: AppVersionComparisonCard(local: local, remote: offer.version, pairingCode: null),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            key: const Key('paired-app-update-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(force ? '强制安装' : '升级'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await ref.read(deviceSyncControllerProvider.notifier).installAppFrom(deviceId, force: force);
    }
  }
}
