/// 局域网同步页的配对设备弹层与手动操作编排。
///
/// 设备状态和事务仍由 DeviceSyncController 持有；本文件只连接正式页面入口与确认流程。
part of 'lan_sync_page.dart';

extension _LanSyncPairedDeviceActions on _LanSyncPageState {
  Future<void> _manageDevice(PairedDevice device) async {
    await showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: AppMotion.overlayStyle(context),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DeviceSettingsSheet(deviceId: device.deviceId),
    );
  }

  Future<void> _showAddDeviceSheet({bool beginPairing = true}) async {
    final controller = ref.read(deviceSyncControllerProvider.notifier);
    if (beginPairing && !ref.read(deviceSyncControllerProvider).pairingBusy) unawaited(controller.beginPairing());
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: AppMotion.overlayStyle(context),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => Consumer(
        builder: (context, ref, _) => DevicePairingSheet(
          state: ref.watch(deviceSyncControllerProvider),
          onBeginPairing: () => unawaited(ref.read(deviceSyncControllerProvider.notifier).beginPairing()),
          onApprovePairing: () => unawaited(ref.read(deviceSyncControllerProvider.notifier).approvePairing()),
          onRejectPairing: () => unawaited(ref.read(deviceSyncControllerProvider.notifier).rejectPairing()),
          onCancelPairing: () {
            unawaited(ref.read(deviceSyncControllerProvider.notifier).cancelPairing());
            Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  Future<void> _showAllDevicesSheet() => showModalBottomSheet<void>(
    context: context,
    sheetAnimationStyle: AppMotion.overlayStyle(context),
    showDragHandle: true,
    builder: (sheetContext) {
      return Consumer(
        builder: (context, ref, _) => _AllDevicesSheet(
          state: ref.watch(deviceSyncControllerProvider),
          onManage: (device) {
            Navigator.of(sheetContext).pop();
            unawaited(_manageDevice(device));
          },
          onSync: (deviceId, operation) =>
              unawaited(ref.read(deviceSyncControllerProvider.notifier).syncNow(deviceId, operation: operation)),
          onAppUpdate: (deviceId, force) => unawaited(_confirmPairedAppUpdate(deviceId, force)),
        ),
      );
    },
  );
}
