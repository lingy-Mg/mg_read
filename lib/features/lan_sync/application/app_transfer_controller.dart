/// 临时 App 发送、扫码接收和安装状态所有者。
///
/// 职责：串行持有一次性 HTTP 服务或接收连接，向 UI 投影双方版本、确认码、
/// 下载进度与系统安装器启动结果。离开页面会关闭会话，不影响已配对数据同步宿主。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/features/lan_sync/application/app_update_service.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_screen_awake.dart';
import 'package:mg_read/features/lan_sync/data/app_transfer_transport.dart';
import 'package:mg_read/features/lan_sync/domain/app_transfer_qr_payload.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';

final appTransferControllerProvider = NotifierProvider.autoDispose<AppTransferController, AppTransferState>(AppTransferController.new);

enum AppTransferPhase { idle, preparing, awaitingQr, waitingForPeer, pairing, ready, downloading, launchingInstaller, completed, failed }

enum AppTransferRole { sender, receiver }

final class AppTransferState {
  const AppTransferState({
    this.phase = AppTransferPhase.idle,
    this.role,
    this.message = '选择发送或获取 App',
    this.localVersion,
    this.remoteVersion,
    this.offeredVersion,
    this.connectionOffer,
    this.pairingCode,
    this.transferredBytes = 0,
    this.totalBytes = 0,
    this.errorCode,
  });

  final AppTransferPhase phase;
  final AppTransferRole? role;
  final String message;
  final AppVersionInfo? localVersion;
  final AppVersionInfo? remoteVersion;
  final AppVersionInfo? offeredVersion;
  final AppTransferConnectionOffer? connectionOffer;
  final String? pairingCode;
  final int transferredBytes;
  final int totalBytes;
  final String? errorCode;

  double? get progress => totalBytes <= 0 ? null : (transferredBytes / totalBytes).clamp(0, 1);
  bool get active => phase != AppTransferPhase.idle && phase != AppTransferPhase.completed && phase != AppTransferPhase.failed;
  bool get remoteIsUpgrade => localVersion != null && offeredVersion != null && isRemoteAppUpgrade(offeredVersion!, localVersion!);

  AppTransferState copyWith({
    AppTransferPhase? phase,
    AppTransferRole? role,
    String? message,
    AppVersionInfo? localVersion,
    AppVersionInfo? remoteVersion,
    AppVersionInfo? offeredVersion,
    AppTransferConnectionOffer? connectionOffer,
    String? pairingCode,
    int? transferredBytes,
    int? totalBytes,
    String? errorCode,
  }) => AppTransferState(
    phase: phase ?? this.phase,
    role: role ?? this.role,
    message: message ?? this.message,
    localVersion: localVersion ?? this.localVersion,
    remoteVersion: remoteVersion ?? this.remoteVersion,
    offeredVersion: offeredVersion ?? this.offeredVersion,
    connectionOffer: connectionOffer ?? this.connectionOffer,
    pairingCode: pairingCode ?? this.pairingCode,
    transferredBytes: transferredBytes ?? this.transferredBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    errorCode: errorCode,
  );
}

final class AppTransferController extends Notifier<AppTransferState> {
  AppTransferSenderService? _sender;
  AppTransferReceiverConnection? _receiver;
  StreamSubscription<AppTransferSenderEvent>? _senderSubscription;
  LanSyncScreenAwake? _senderAwake;
  bool _disposed = false;

  @override
  AppTransferState build() {
    ref.onDispose(() {
      _disposed = true;
      unawaited(_close());
    });
    return const AppTransferState();
  }

  Future<void> startSending() async {
    await _restart(AppTransferRole.sender, '正在准备可发送的 App 版本');
    _senderAwake = LanSyncScreenAwake();
    try {
      final sender = await AppTransferSenderService.start(ref.read(appUpdateServiceProvider));
      if (_disposed) return await sender.close();
      _sender = sender;
      _senderSubscription = sender.events.listen(_onSenderEvent);
      state = state.copyWith(
        phase: AppTransferPhase.waitingForPeer,
        message: '等待另一台设备扫码',
        localVersion: sender.localVersion,
        connectionOffer: sender.connectionOffer,
      );
    } on Object catch (error) {
      await _releaseSenderAwake();
      _fail(error);
    }
  }

  Future<void> startReceiving() async {
    await _restart(AppTransferRole.receiver, '请扫描发送 App 设备显示的二维码');
    try {
      final local = await ref.read(appUpdateServiceProvider).currentVersion();
      if (_disposed) return;
      state = state.copyWith(phase: AppTransferPhase.awaitingQr, message: '请扫描发送 App 设备显示的二维码', localVersion: local);
    } on Object catch (error) {
      _fail(error);
    }
  }

  Future<void> connectOffer(AppTransferConnectionOffer offer) async {
    try {
      final local = state.localVersion ?? await ref.read(appUpdateServiceProvider).currentVersion();
      state = state.copyWith(
        phase: AppTransferPhase.preparing,
        role: AppTransferRole.receiver,
        message: '正在连接发送 App 的设备',
        localVersion: local,
      );
      final receiver = await AppTransferReceiverConnection.connectAny(offer, local);
      if (_disposed) return receiver.close();
      _receiver = receiver;
      state = state.copyWith(
        phase: AppTransferPhase.ready,
        role: AppTransferRole.receiver,
        message: '请核对版本并确认安装',
        localVersion: local,
        offeredVersion: receiver.remoteOffer.version,
        pairingCode: receiver.pairingCode,
      );
    } on Object catch (error) {
      _fail(error);
    }
  }

  Future<void> install({required bool force}) async {
    final receiver = _receiver;
    final local = state.localVersion;
    if (receiver == null || local == null || state.phase != AppTransferPhase.ready) return;
    final service = ref.read(appUpdateServiceProvider);
    try {
      await service.ensureInstallPermission();
    } on Object catch (error) {
      final code = _appTransferErrorCode(error);
      if (code == 'app_update_install_permission_required' && !_disposed) {
        state = state.copyWith(phase: AppTransferPhase.ready, message: _appTransferMessage(code), errorCode: code);
      } else {
        _fail(error, code: code);
      }
      return;
    }
    state = state.copyWith(phase: AppTransferPhase.downloading, message: '正在下载并校验 App 安装包');
    try {
      await LanSyncScreenAwake.run(
        () => receiver.downloadAndInstall(
          service,
          local,
          force: force,
          onProgress: (bytes, total) {
            if (_disposed) return;
            state = state.copyWith(
              phase: bytes == total ? AppTransferPhase.launchingInstaller : AppTransferPhase.downloading,
              message: bytes == total ? '安装包校验完成，正在打开系统安装程序' : '正在下载并校验 App 安装包',
              transferredBytes: bytes,
              totalBytes: total,
            );
          },
        ),
      );
      if (!_disposed) state = state.copyWith(phase: AppTransferPhase.completed, message: '已打开系统安装程序，请按提示完成升级');
    } on Object catch (error) {
      _fail(error);
    }
  }

  Future<void> reset() async {
    await _close();
    if (!_disposed) state = const AppTransferState();
  }

  Future<void> cancel() => reset();

  Future<void> _restart(AppTransferRole role, String message) async {
    await _close();
    state = AppTransferState(phase: AppTransferPhase.preparing, role: role, message: message);
  }

  void _onSenderEvent(AppTransferSenderEvent event) {
    if (_disposed) return;
    switch (event) {
      case AppTransferSenderPairing():
        state = state.copyWith(
          phase: AppTransferPhase.pairing,
          message: '对方正在核对版本并确认安装',
          remoteVersion: event.remoteVersion,
          offeredVersion: event.offeredVersion,
          pairingCode: event.code,
        );
      case AppTransferSenderProgress():
        state = state.copyWith(
          phase: AppTransferPhase.downloading,
          message: '正在向对方发送 App 安装包',
          transferredBytes: event.bytes,
          totalBytes: event.total,
        );
      case AppTransferSenderDone():
        unawaited(_releaseSenderAwake());
        state = state.copyWith(phase: AppTransferPhase.completed, message: 'App 安装包已发送，对方正在完成系统安装');
      case AppTransferSenderFailed():
        unawaited(_releaseSenderAwake());
        _fail(event.error ?? StateError(event.code), code: event.code);
    }
  }

  void _fail(Object error, {String? code}) {
    if (_disposed) return;
    final errorCode = code ?? _appTransferErrorCode(error);
    state = state.copyWith(phase: AppTransferPhase.failed, message: _appTransferMessage(errorCode), errorCode: errorCode);
  }

  Future<void> _close() async {
    await _senderSubscription?.cancel();
    _senderSubscription = null;
    final sender = _sender;
    _sender = null;
    await sender?.close();
    await _releaseSenderAwake();
    _receiver?.close();
    _receiver = null;
  }

  Future<void> _releaseSenderAwake() async {
    final awake = _senderAwake;
    _senderAwake = null;
    await awake?.close();
  }
}

String _appTransferErrorCode(Object error) {
  final match = RegExp(r'(app_update_[a-z_]+|lan_sync_[a-z_]+)').firstMatch(error.toString());
  return match?.group(1) ?? 'app_update_failed';
}

String _appTransferMessage(String code) => switch (code) {
  'app_update_not_newer' => '对方版本不高于本机；如确实需要，请选择强制安装',
  'app_update_platform_mismatch' => '对方没有适用于当前设备平台的 App 安装包',
  'app_update_package_unavailable' => '本机没有可发送的 App 安装包',
  'app_update_install_permission_required' => '请在系统设置中允许安装未知来源应用，返回后再次确认升级',
  'app_update_installer_unavailable' => '系统中没有可用的 APK 安装程序',
  'app_update_installer_permission_denied' => '系统拒绝向安装程序授予 APK 读取权限',
  'app_update_file_provider_failed' => '安装包临时文件无法提供给系统安装程序',
  'app_update_installer_failed' => '系统安装程序启动失败',
  'lan_sync_local_network_unavailable' => '未找到可用的私有局域网地址',
  _ => 'App 传输未完成（$code）',
};
