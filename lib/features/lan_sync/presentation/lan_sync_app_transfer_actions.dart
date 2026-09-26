/// 局域网同步页的 App 扫码与安装确认动作。
///
/// 发送与接收共用持续可见的面板，覆盖确认、权限返回、下载与失败重试；
/// 关闭面板即取消本次会话，传输和安装状态仍由应用控制器持有。
part of 'lan_sync_page.dart';

extension _LanSyncAppTransferActions on _LanSyncPageState {
  Future<void> _showAppTransferSheet({AppTransferConnectionOffer? offer}) async {
    final controller = ref.read(appTransferControllerProvider.notifier);
    unawaited(offer == null ? controller.startSending() : controller.connectOffer(offer));
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => Consumer(
        builder: (context, ref, _) {
          final appState = ref.watch(appTransferControllerProvider);
          return LanSyncSheetFrame(
            title: offer == null ? '发送 App' : '接收 App',
            description: offer == null ? '生成二维码后，对方使用 MgRead 内的“扫码”即可继续。' : '核对双方版本和确认码后安装，传输进度和安装结果会显示在这里。',
            closeLabel: appState.active ? '取消 App 传输' : '关闭',
            onClose: () {
              if (appState.active) unawaited(ref.read(appTransferControllerProvider.notifier).cancel());
              Navigator.of(sheetContext).pop();
            },
            footer: appState.phase == AppTransferPhase.completed || appState.phase == AppTransferPhase.failed
                ? FilledButton(
                    key: const Key('app-transfer-finish'),
                    onPressed: () {
                      unawaited(ref.read(appTransferControllerProvider.notifier).reset());
                      Navigator.of(sheetContext).pop();
                    },
                    child: const Text('完成'),
                  )
                : null,
            child: AppTransferPanel(
              state: appState,
              showActions: false,
              onScanQr: null,
              onInstall: (force) => unawaited(ref.read(appTransferControllerProvider.notifier).install(force: force)),
              onCancel: () {
                unawaited(ref.read(appTransferControllerProvider.notifier).cancel());
                Navigator.of(sheetContext).pop();
              },
              onReset: () {
                unawaited(ref.read(appTransferControllerProvider.notifier).reset());
                Navigator.of(sheetContext).pop();
              },
            ),
          );
        },
      ),
    );
    if (mounted) await ref.read(appTransferControllerProvider.notifier).cancel();
  }

  Future<void> _connectScannedAppOffer(AppTransferConnectionOffer offer) => _showAppTransferSheet(offer: offer);

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
