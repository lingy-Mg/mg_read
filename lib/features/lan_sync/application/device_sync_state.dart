/// 配对流程与设备同步页面的不可变状态。
part of 'device_sync_controller.dart';

enum DevicePairingPhase { idle, creatingOffer, showingOffer, confirming, joining, waitingApproval, completed, failed }

final class DeviceSyncState {
  const DeviceSyncState({
    this.devices = const <PairedDevice>[],
    this.onlineDeviceIds = const <String>{},
    this.busyDeviceId,
    this.lastMessage,
    this.lastErrorCode,
    this.pairingPhase = DevicePairingPhase.idle,
    this.pairingOffer,
    this.pairingCode,
    this.pairingPeer,
    this.started = false,
  });

  final List<PairedDevice> devices;
  final Set<String> onlineDeviceIds;
  final String? busyDeviceId;
  final String? lastMessage;
  final String? lastErrorCode;
  final DevicePairingPhase pairingPhase;
  final LanPairingOffer? pairingOffer;
  final String? pairingCode;
  final PairedDevice? pairingPeer;
  final bool started;

  bool get pairingBusy => switch (pairingPhase) {
    DevicePairingPhase.creatingOffer ||
    DevicePairingPhase.showingOffer ||
    DevicePairingPhase.confirming ||
    DevicePairingPhase.joining ||
    DevicePairingPhase.waitingApproval => true,
    _ => false,
  };

  DeviceSyncState copyWith({
    List<PairedDevice>? devices,
    Set<String>? onlineDeviceIds,
    Object? busyDeviceId = _unchanged,
    Object? lastMessage = _unchanged,
    Object? lastErrorCode = _unchanged,
    DevicePairingPhase? pairingPhase,
    Object? pairingOffer = _unchanged,
    Object? pairingCode = _unchanged,
    Object? pairingPeer = _unchanged,
    bool? started,
  }) => DeviceSyncState(
    devices: devices ?? this.devices,
    onlineDeviceIds: onlineDeviceIds ?? this.onlineDeviceIds,
    busyDeviceId: identical(busyDeviceId, _unchanged) ? this.busyDeviceId : busyDeviceId as String?,
    lastMessage: identical(lastMessage, _unchanged) ? this.lastMessage : lastMessage as String?,
    lastErrorCode: identical(lastErrorCode, _unchanged) ? this.lastErrorCode : lastErrorCode as String?,
    pairingPhase: pairingPhase ?? this.pairingPhase,
    pairingOffer: identical(pairingOffer, _unchanged) ? this.pairingOffer : pairingOffer as LanPairingOffer?,
    pairingCode: identical(pairingCode, _unchanged) ? this.pairingCode : pairingCode as String?,
    pairingPeer: identical(pairingPeer, _unchanged) ? this.pairingPeer : pairingPeer as PairedDevice?,
    started: started ?? this.started,
  );
}

const Object _unchanged = Object();
