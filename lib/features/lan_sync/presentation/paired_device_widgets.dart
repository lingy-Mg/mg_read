/// 已配对设备列表、首次配对面板和逐设备策略编辑。
///

/// 本文件只负责交互呈现；发现、密钥和同步事务仍由 DeviceSyncController 持有。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';
import 'package:mg_read/features/lan_sync/domain/lan_pairing_payload.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

class PairedDevicesSection extends StatelessWidget {
  const PairedDevicesSection({
    required this.state,
    required this.supportsScanner,
    required this.onBeginPairing,
    required this.onApprovePairing,
    required this.onRejectPairing,
    required this.onCancelPairing,
    required this.onSync,
    required this.onManage,
    this.onScanPairing,
    this.onAppUpdate,
    super.key,
  });

  final DeviceSyncState state;
  final bool supportsScanner;
  final VoidCallback onBeginPairing;
  final VoidCallback? onScanPairing;
  final VoidCallback onApprovePairing;
  final VoidCallback onRejectPairing;
  final VoidCallback onCancelPairing;
  final void Function(String deviceId, PairedSyncOperation operation) onSync;
  final void Function(String deviceId, bool force)? onAppUpdate;
  final ValueChanged<PairedDevice> onManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        border: Border.all(color: tokens.divider),
        boxShadow: <BoxShadow>[BoxShadow(color: tokens.shadow.withValues(alpha: 0.06), blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.comfortable),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 5,
                  height: 32,
                  margin: const EdgeInsets.only(top: 2, right: AppSpacing.regular),
                  decoration: BoxDecoration(color: tokens.dataSourceAccent, borderRadius: AppRadii.pill),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('我的设备', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: AppSpacing.unit),
                      Text(
                        state.started ? '已在当前网络中发现以下配对设备' : '正在准备自动发现服务…',
                        style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                      ),
                    ],
                  ),
                ),
                if (!state.pairingBusy)
                  TextButton.icon(
                    key: const Key('device-sync-add-device'),
                    onPressed: onBeginPairing,
                    icon: const Icon(Icons.add_link_rounded),
                    label: const Text('添加设备'),
                  ),
              ],
            ),
            if (state.pairingPhase != DevicePairingPhase.idle) ...<Widget>[
              const SizedBox(height: AppSpacing.regular),
              _PairingPanel(
                state: state,
                onApprove: onApprovePairing,
                onReject: onRejectPairing,
                onCancel: onCancelPairing,
                onRetry: onBeginPairing,
              ),
            ],
            if (state.devices.isEmpty && state.pairingPhase == DevicePairingPhase.idle) ...<Widget>[
              const SizedBox(height: AppSpacing.regular),
              DecoratedBox(
                decoration: BoxDecoration(color: tokens.mutedSurface, borderRadius: AppRadii.detailControl),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.comfortable),
                  child: Text(
                    '还没有已配对设备。完成一次配对后，即使 IP 变化也能自动重新发现。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
                  ),
                ),
              ),
            ],
            for (final device in state.devices) ...<Widget>[
              const SizedBox(height: AppSpacing.regular),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: state.onlineDeviceIds.contains(device.deviceId) ? const Color(0xFFFFFAF5) : tokens.mutedSurface,
                  borderRadius: const BorderRadius.all(Radius.circular(16)),
                  border: Border.all(
                    color: state.onlineDeviceIds.contains(device.deviceId)
                        ? tokens.dataSourceAccent.withValues(alpha: 0.38)
                        : tokens.divider,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.comfortable, vertical: AppSpacing.regular),
                  child: _PairedDeviceTile(
                    device: device,
                    online: state.onlineDeviceIds.contains(device.deviceId),
                    busy: state.busyDeviceId == device.deviceId,
                    busyMessage: state.busyDeviceId == device.deviceId ? state.busyMessage : null,
                    appOffer: state.appOffersByDeviceId[device.deviceId],
                    localAppVersion: state.localAppVersion,
                    canStartSync: state.busyDeviceId == null,
                    onSync: (operation) => onSync(device.deviceId, operation),
                    onAppUpdate: onAppUpdate == null ? null : (force) => onAppUpdate!(device.deviceId, force),
                    onManage: () => onManage(device),
                  ),
                ),
              ),
            ],
            if (state.lastMessage case final message?) ...<Widget>[
              const SizedBox(height: AppSpacing.compact),
              if (state.lastErrorCode case final errorCode?)
                _SyncFailureNotice(message: message, errorCode: errorCode, details: state.lastErrorDetails)
              else
                Text(
                  message,
                  key: const Key('device-sync-last-message'),
                  style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// “添加设备”底部弹层的配对流程。
///
/// 只展示真实可用的本机配对码和控制器状态；未配对设备尚无发现协议，不能
/// 将已配对设备列表伪装成可配对的附近设备。
class DevicePairingSheet extends StatelessWidget {
  const DevicePairingSheet({
    required this.state,
    required this.onBeginPairing,
    required this.onApprovePairing,
    required this.onRejectPairing,
    required this.onCancelPairing,
    super.key,
  });

  final DeviceSyncState state;
  final VoidCallback onBeginPairing;
  final VoidCallback onApprovePairing;
  final VoidCallback onRejectPairing;
  final VoidCallback onCancelPairing;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.comfortable, AppSpacing.compact, AppSpacing.comfortable, AppSpacing.comfortable),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('添加设备', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.unit),
            Text('让另一台设备扫描本机配对码，确认后会建立长期同步关系。', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
            const SizedBox(height: AppSpacing.comfortable),
            if (state.pairingPhase == DevicePairingPhase.idle)
              FilledButton.icon(
                key: const Key('device-sync-show-pairing-code'),
                onPressed: onBeginPairing,
                icon: const Icon(Icons.qr_code_rounded),
                label: const Text('显示我的配对码'),
              )
            else
              _PairingPanel(
                state: state,
                onApprove: onApprovePairing,
                onReject: onRejectPairing,
                onCancel: onCancelPairing,
                onRetry: onBeginPairing,
              ),
            const SizedBox(height: AppSpacing.regular),
            Text('若要连接另一台设备显示的配对码，请使用页面顶部的“扫码连接 / 接收”。', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
            const SizedBox(height: AppSpacing.compact),
            TextButton(
              onPressed: () {
                onCancelPairing();
                Navigator.of(context).pop();
              },
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SyncFailureNotice extends StatelessWidget {
  const _SyncFailureNotice({required this.message, required this.errorCode, required this.details});

  final String message;
  final String errorCode;
  final String? details;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.errorContainer.withValues(alpha: 0.45),
        borderRadius: AppRadii.detailControl,
        border: Border.all(color: colors.error.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.compact),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              message,
              key: const Key('device-sync-last-message'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.error, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: AppSpacing.unit),
            SelectableText(
              details ?? '错误码：$errorCode',
              key: const Key('device-sync-error-details'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onErrorContainer),
            ),
            const SizedBox(height: AppSpacing.unit),
            Text(
              'Debug 构建的完整异常与堆栈已输出到调试控制台。',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colors.onErrorContainer.withValues(alpha: 0.75)),
            ),
          ],
        ),
      ),
    );
  }
}

class _PairedDeviceTile extends StatelessWidget {
  const _PairedDeviceTile({
    required this.device,
    required this.online,
    required this.busy,
    required this.busyMessage,
    required this.appOffer,
    required this.localAppVersion,
    required this.canStartSync,
    required this.onSync,
    required this.onManage,
    required this.onAppUpdate,
  });

  final PairedDevice device;
  final bool online;
  final bool busy;
  final String? busyMessage;
  final AppPackageOffer? appOffer;
  final AppVersionInfo? localAppVersion;
  final bool canStartSync;
  final ValueChanged<PairedSyncOperation> onSync;
  final VoidCallback onManage;
  final ValueChanged<bool>? onAppUpdate;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final actionsEnabled = online && canStartSync;
    const compactButtonStyle = ButtonStyle(visualDensity: VisualDensity.compact);
    final Widget identity = Row(
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(color: online ? tokens.accentSoft : tokens.surface, borderRadius: AppRadii.detailControl),
          child: SizedBox.square(
            dimension: 52,
            child: Icon(switch (device.platform) {
              PairedDevicePlatform.android => Icons.phone_android_rounded,
              PairedDevicePlatform.windows || PairedDevicePlatform.macos => Icons.computer_rounded,
              PairedDevicePlatform.unknown => Icons.devices_other_rounded,
            }, color: online ? tokens.dataSourceAccent : tokens.mutedText),
          ),
        ),
        const SizedBox(width: AppSpacing.regular),
        Expanded(
          child: InkWell(
            key: Key('device-sync-manage-${device.deviceId}'),
            borderRadius: AppRadii.detailControl,
            onTap: onManage,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.compact),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(device.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.unit),
                  Text(
                    busy
                        ? busyMessage ?? '正在处理同步内容'
                        : online
                        ? '在线 · ${device.autoSync ? '自动同步已开启' : '仅手动'}'
                        : '离线 · 打开另一台设备后可同步',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: online ? tokens.success : tokens.mutedText),
                  ),
                  if (device.lastSyncAtUtc != null)
                    Text(_lastSyncText(device), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
                  if (online && appOffer != null)
                    Text(
                      '对方 App ${appOffer!.version.displayVersion}${_appUpgradeAvailable ? ' · 有新版本' : ''}',
                      key: Key('device-sync-app-version-${device.deviceId}'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _appUpgradeAvailable ? tokens.dataSourceAccent : tokens.mutedText,
                        fontWeight: _appUpgradeAvailable ? FontWeight.w700 : null,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
    final Widget actions = Wrap(
      spacing: AppSpacing.compact,
      runSpacing: AppSpacing.unit,
      children: <Widget>[
        OutlinedButton.icon(
          key: Key('device-sync-pull-${device.deviceId}'),
          style: compactButtonStyle,
          onPressed: actionsEnabled && device.canReceive ? () => onSync(PairedSyncOperation.pull) : null,
          icon: const Icon(Icons.file_download_outlined, size: 18),
          label: const Text('拉取'),
        ),
        OutlinedButton.icon(
          key: Key('device-sync-push-${device.deviceId}'),
          style: compactButtonStyle,
          onPressed: actionsEnabled && device.canSend ? () => onSync(PairedSyncOperation.push) : null,
          icon: const Icon(Icons.file_upload_outlined, size: 18),
          label: const Text('推送'),
        ),
        if (online && appOffer?.available == true && onAppUpdate != null)
          _appUpgradeAvailable
              ? FilledButton.tonalIcon(
                  key: Key('device-sync-app-upgrade-${device.deviceId}'),
                  style: compactButtonStyle,
                  onPressed: actionsEnabled ? () => onAppUpdate!(false) : null,
                  icon: const Icon(Icons.system_update_alt_rounded, size: 18),
                  label: const Text('升级 App'),
                )
              : OutlinedButton.icon(
                  key: Key('device-sync-app-force-${device.deviceId}'),
                  style: compactButtonStyle,
                  onPressed: actionsEnabled ? () => onAppUpdate!(true) : null,
                  icon: const Icon(Icons.replay_rounded, size: 18),
                  label: const Text('强制安装'),
                ),
      ],
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth >= 680) {
          return Row(
            children: <Widget>[
              Expanded(child: identity),
              const SizedBox(width: AppSpacing.comfortable),
              actions,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            identity,
            const SizedBox(height: AppSpacing.compact),
            Align(alignment: Alignment.centerRight, child: actions),
          ],
        );
      },
    );
  }

  bool get _appUpgradeAvailable =>
      appOffer?.available == true && localAppVersion != null && isRemoteAppUpgrade(appOffer!.version, localAppVersion!);
}

class _PairingPanel extends StatelessWidget {
  const _PairingPanel({
    required this.state,
    required this.onApprove,
    required this.onReject,
    required this.onCancel,
    required this.onRetry,
  });

  final DeviceSyncState state;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final offer = state.pairingOffer;
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLow, borderRadius: AppRadii.detailControl),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: Column(
          children: <Widget>[
            if (state.pairingPhase == DevicePairingPhase.creatingOffer || state.pairingPhase == DevicePairingPhase.joining) ...<Widget>[
              const CircularProgressIndicator(),
              const SizedBox(height: AppSpacing.compact),
              Text(state.pairingPhase == DevicePairingPhase.joining ? '正在建立加密配对连接' : '正在生成一次性配对码'),
            ] else if (state.pairingPhase == DevicePairingPhase.showingOffer && offer != null) ...<Widget>[
              Text('扫描以配对', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.regular),
              ColoredBox(
                color: colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.compact),
                  child: QrImageView(
                    key: const Key('device-sync-pairing-qr'),
                    data: LanPairingQrPayload.encode(offer),
                    version: QrVersions.auto,
                    size: 220,
                    backgroundColor: colorScheme.surface,
                    eyeStyle: QrEyeStyle(color: colorScheme.onSurface),
                    dataModuleStyle: QrDataModuleStyle(color: colorScheme.onSurface),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.compact),
              const Text('二维码十分钟内有效。另一台设备扫码后，请核对双方验证码。'),
              TextButton(onPressed: onCancel, child: const Text('取消')),
            ] else if (state.pairingPhase == DevicePairingPhase.confirming) ...<Widget>[
              Text('是否配对 ${state.pairingPeer?.label ?? '这台设备'}？'),
              const SizedBox(height: AppSpacing.compact),
              SelectableText(
                state.pairingCode ?? '------',
                key: const Key('device-sync-pairing-code'),
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(letterSpacing: 5, fontWeight: FontWeight.w700),
              ),
              const Text('确认两台设备显示的六位数字一致。此授权只需要一次。'),
              const SizedBox(height: AppSpacing.regular),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(onPressed: onReject, child: const Text('不是这台设备')),
                  ),
                  const SizedBox(width: AppSpacing.compact),
                  Expanded(
                    child: FilledButton(onPressed: onApprove, child: const Text('一致，允许配对')),
                  ),
                ],
              ),
            ] else if (state.pairingPhase == DevicePairingPhase.waitingApproval) ...<Widget>[
              Text('等待 ${state.pairingPeer?.label ?? '另一台设备'} 批准'),
              const SizedBox(height: AppSpacing.compact),
              SelectableText(
                state.pairingCode ?? '------',
                key: const Key('device-sync-pairing-code'),
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(letterSpacing: 5, fontWeight: FontWeight.w700),
              ),
              const Text('请确认另一台设备显示相同数字，并在那边允许配对。'),
              TextButton(onPressed: onCancel, child: const Text('取消')),
            ] else if (state.pairingPhase == DevicePairingPhase.completed) ...<Widget>[
              const Icon(Icons.verified_rounded, color: Colors.green, size: 32),
              const SizedBox(height: AppSpacing.compact),
              const Text('配对完成。以后两端打开即可自动同步。'),
              TextButton(onPressed: onCancel, child: const Text('完成')),
            ] else if (state.pairingPhase == DevicePairingPhase.failed) ...<Widget>[
              Icon(Icons.error_outline_rounded, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: AppSpacing.compact),
              Text(_pairingFailureMessage(state.lastErrorCode)),
              if (state.lastErrorDetails case final details?) ...<Widget>[
                const SizedBox(height: AppSpacing.compact),
                SelectableText(
                  '错误码：${state.lastErrorCode ?? 'device_pairing_failed'}\n$details',
                  key: const Key('device-pairing-error-details'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  TextButton(onPressed: onCancel, child: const Text('取消')),
                  FilledButton.tonal(onPressed: onRetry, child: const Text('重新配对')),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _pairingFailureMessage(String? code) => switch (code) {
  'device_pairing_offer_expired' => '配对码已过期，请重新生成。',
  'lan_sync_wifi_required' => '手机未连接 Wi-Fi，无法开始配对。',
  'lan_sync_local_network_unavailable' || 'lan_sync_address_not_private' => '未检测到可用的私有局域网地址。',
  'lan_sync_connect_timeout' => '连接配对设备超时，请检查防火墙和局域网访问权限。',
  'lan_sync_http_failed' || 'lan_sync_connect_failed' => '无法建立局域网 HTTP 连接，请检查代理、防火墙和两端网络。',
  'lan_sync_pairing_invalid' || 'lan_sync_handshake_invalid' => '配对响应无效，请重新生成二维码。',
  'lan_sync_pairing_rejected' => '另一台设备已拒绝配对。',
  _ => '配对未完成，请根据下方错误信息检查后重试。',
};

class DeviceSettingsSheet extends ConsumerWidget {
  const DeviceSettingsSheet({required this.deviceId, super.key});

  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(deviceSyncControllerProvider).devices;
    final matches = devices.where((item) => item.deviceId == deviceId);
    if (matches.isEmpty) return const SizedBox.shrink();
    final device = matches.single;
    final controller = ref.read(deviceSyncControllerProvider.notifier);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.regular, 0, AppSpacing.regular, AppSpacing.regular),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(device.label, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.compact),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动同步'),
              subtitle: const Text('两端都打开后自动检查变化'),
              value: device.autoSync,
              onChanged: (value) => controller.updateDeviceSettings(device.deviceId, autoSync: value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('数据源插件'),
              subtitle: const Text('包含正式插件和开发书源副本'),
              value: device.syncPlugins,
              onChanged: (value) => controller.updateDeviceSettings(device.deviceId, syncPlugins: value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('书架与阅读进度'),
              subtitle: const Text('单向同步，发送端覆盖本机数据'),
              value: device.syncBookshelf,
              onChanged: (value) => controller.updateDeviceSettings(device.deviceId, syncBookshelf: value),
            ),
            const SizedBox(height: AppSpacing.compact),
            Text('同步方向', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: AppSpacing.compact),
            SegmentedButton<PairedSyncMode>(
              segments: const <ButtonSegment<PairedSyncMode>>[
                ButtonSegment(value: PairedSyncMode.bidirectional, label: Text('双向')),
                ButtonSegment(value: PairedSyncMode.receiveOnly, label: Text('仅接收')),
                ButtonSegment(value: PairedSyncMode.sendOnly, label: Text('仅发送')),
              ],
              selected: <PairedSyncMode>{device.mode},
              onSelectionChanged: (value) => controller.updateDeviceSettings(device.deviceId, mode: value.single),
            ),
            const SizedBox(height: AppSpacing.regular),
            TextButton.icon(
              key: const Key('device-sync-remove-device'),
              onPressed: () => _confirmRemove(context, controller, device),
              icon: const Icon(Icons.link_off_rounded),
              label: const Text('解除配对'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, DeviceSyncController controller, PairedDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('解除配对？'),
        content: Text('将删除 ${device.label} 的本机信任密钥。另一台设备也需要单独解除配对。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('解除')),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.removeDevice(device.deviceId);
    if (context.mounted) Navigator.pop(context);
  }
}

String _lastSyncText(PairedDevice device) {
  final local = device.lastSyncAtUtc!.toLocal();
  final minute = local.minute.toString().padLeft(2, '0');
  final result = switch (device.lastSyncResult) {
    PairedSyncResultState.success => '成功',
    PairedSyncResultState.partial => '部分完成',
    PairedSyncResultState.failed => '失败',
    PairedSyncResultState.cancelled => '已取消',
    null => '未知',
  };
  return '上次同步 ${local.month}/${local.day} ${local.hour}:$minute · $result';
}
