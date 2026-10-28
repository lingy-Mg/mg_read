/// 局域网同步主页的能力卡片与临时传输弹层。
///
/// 这些组件只呈现页面已经持有的状态和操作入口，不建立连接或修改传输协议。
part of 'lan_sync_page.dart';

class _DeviceSyncCard extends StatelessWidget {
  const _DeviceSyncCard({
    required this.state,
    required this.onAddDevice,
    required this.onManage,
    required this.onSync,
    required this.onAppUpdate,
    required this.onShowAll,
  });

  final DeviceSyncState state;
  final VoidCallback onAddDevice;
  final ValueChanged<PairedDevice> onManage;
  final void Function(String deviceId, PairedSyncOperation operation) onSync;
  final void Function(String deviceId, bool force) onAppUpdate;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final displayed = state.devices.take(3).toList(growable: false);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.card,
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.comfortable),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('设备同步', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.unit),
            Text('配对一次，后续在同一局域网内自动发现并同步', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
            const SizedBox(height: AppSpacing.regular),
            if (displayed.isEmpty)
              DecoratedBox(
                decoration: BoxDecoration(color: tokens.mutedSurface, borderRadius: AppRadii.detailControl),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.regular),
                  child: Column(
                    children: <Widget>[
                      Icon(Icons.devices_other_rounded, color: tokens.mutedText),
                      const SizedBox(height: AppSpacing.compact),
                      Text('暂无同步设备', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: AppSpacing.unit),
                      Text('添加设备后，可在局域网内自动发现', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
                    ],
                  ),
                ),
              )
            else
              for (final device in displayed) ...<Widget>[
                _DeviceSummaryTile(
                  device: device,
                  online: state.onlineDeviceIds.contains(device.deviceId),
                  busy: state.busyDeviceId == device.deviceId,
                  busyMessage: state.busyMessage,
                  appOffer: state.appOffersByDeviceId[device.deviceId],
                  localAppVersion: state.localAppVersion,
                  canStartAction: state.busyDeviceId == null,
                  onTap: () => onManage(device),
                  onSync: (operation) => onSync(device.deviceId, operation),
                  onAppUpdate: (force) => onAppUpdate(device.deviceId, force),
                ),
                if (device != displayed.last) Divider(color: tokens.divider, height: AppSpacing.section),
              ],
            if (state.devices.length > displayed.length) ...<Widget>[
              const SizedBox(height: AppSpacing.compact),
              TextButton(onPressed: onShowAll, child: Text('查看全部 ${state.devices.length} 台设备')),
            ],
            const SizedBox(height: AppSpacing.regular),
            FilledButton.icon(
              key: const Key('device-sync-add-device'),
              onPressed: onAddDevice,
              icon: const Icon(Icons.add_link_rounded),
              label: const Text('添加设备'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceSummaryTile extends StatelessWidget {
  const _DeviceSummaryTile({
    required this.device,
    required this.online,
    required this.busy,
    required this.busyMessage,
    required this.appOffer,
    required this.localAppVersion,
    required this.canStartAction,
    required this.onTap,
    required this.onSync,
    required this.onAppUpdate,
  });

  final PairedDevice device;
  final bool online;
  final bool busy;
  final String? busyMessage;
  final AppPackageOffer? appOffer;
  final AppVersionInfo? localAppVersion;
  final bool canStartAction;
  final VoidCallback onTap;
  final ValueChanged<PairedSyncOperation> onSync;
  final ValueChanged<bool> onAppUpdate;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final status = busy
        ? '正在同步'
        : online
        ? '在线'
        : '离线';
    final detail = busy
        ? busyMessage ?? '正在处理同步内容'
        : device.lastSyncAtUtc == null
        ? (online ? '等待同步' : '打开另一台设备后可同步')
        : '最近同步：${_relativeTime(device.lastSyncAtUtc!)}';
    final actionsEnabled = online && canStartAction;
    final appUpgradeAvailable =
        appOffer?.available == true && localAppVersion != null && isRemoteAppUpgrade(appOffer!.version, localAppVersion!);
    const compactButtonStyle = ButtonStyle(visualDensity: VisualDensity.compact);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.compact),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            key: Key('device-sync-manage-${device.deviceId}'),
            borderRadius: AppRadii.detailControl,
            onTap: onTap,
            child: Row(
              children: <Widget>[
                DecoratedBox(
                  decoration: BoxDecoration(color: online ? tokens.accentSoft : tokens.mutedSurface, borderRadius: AppRadii.detailControl),
                  child: SizedBox.square(
                    dimension: 42,
                    child: Icon(_platformIcon(device.platform), color: online ? tokens.success : tokens.mutedText),
                  ),
                ),
                const SizedBox(width: AppSpacing.regular),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(device.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: AppSpacing.unit),
                      Text(
                        '$status · $detail',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: online ? tokens.success : tokens.mutedText),
                      ),
                      if (online && appOffer != null)
                        Text(
                          '对方 App ${appOffer!.version.displayVersion}${appUpgradeAvailable ? ' · 有新版本' : ''}',
                          key: Key('device-sync-app-version-${device.deviceId}'),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: appUpgradeAvailable ? tokens.accent : tokens.mutedText,
                            fontWeight: appUpgradeAvailable ? FontWeight.w700 : null,
                          ),
                        ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.compact),
          Wrap(
            alignment: WrapAlignment.end,
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
              if (online && appOffer?.available == true)
                appUpgradeAvailable
                    ? FilledButton.tonalIcon(
                        key: Key('device-sync-app-upgrade-${device.deviceId}'),
                        style: compactButtonStyle,
                        onPressed: actionsEnabled ? () => onAppUpdate(false) : null,
                        icon: const Icon(Icons.system_update_alt_rounded, size: 18),
                        label: const Text('升级 App'),
                      )
                    : OutlinedButton.icon(
                        key: Key('device-sync-app-force-${device.deviceId}'),
                        style: compactButtonStyle,
                        onPressed: actionsEnabled ? () => onAppUpdate(true) : null,
                        icon: const Icon(Icons.replay_rounded, size: 18),
                        label: const Text('强制安装'),
                      ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String description;
  final String actionLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Material(
      color: tokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadii.card,
        side: BorderSide(color: tokens.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.regular),
          child: Row(
            children: <Widget>[
              DecoratedBox(
                decoration: BoxDecoration(color: tokens.accentSoft, borderRadius: AppRadii.detailControl),
                child: SizedBox.square(dimension: 44, child: Icon(icon, color: tokens.accent)),
              ),
              const SizedBox(width: AppSpacing.regular),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: AppSpacing.unit),
                    Text(description, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
                  ],
                ),
              ),
              Text(actionLabel, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: tokens.accent)),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class _AllDevicesSheet extends StatelessWidget {
  const _AllDevicesSheet({required this.state, required this.onManage, required this.onSync, required this.onAppUpdate});

  final DeviceSyncState state;
  final ValueChanged<PairedDevice> onManage;
  final void Function(String deviceId, PairedSyncOperation operation) onSync;
  final void Function(String deviceId, bool force) onAppUpdate;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.comfortable, AppSpacing.compact, AppSpacing.comfortable, AppSpacing.comfortable),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('同步设备', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.regular),
            Flexible(
              child: SingleChildScrollView(
                key: const Key('device-sync-all-devices-scroll'),
                child: Column(
                  children: <Widget>[
                    for (final device in state.devices)
                      _DeviceSummaryTile(
                        device: device,
                        online: state.onlineDeviceIds.contains(device.deviceId),
                        busy: state.busyDeviceId == device.deviceId,
                        busyMessage: state.busyMessage,
                        appOffer: state.appOffersByDeviceId[device.deviceId],
                        localAppVersion: state.localAppVersion,
                        canStartAction: state.busyDeviceId == null,
                        onTap: () => onManage(device),
                        onSync: (operation) => onSync(device.deviceId, operation),
                        onAppUpdate: (force) => onAppUpdate(device.deviceId, force),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _TemporaryDataSheet extends StatelessWidget {
  const _TemporaryDataSheet({
    required this.state,
    required this.receiving,
    required this.onCancel,
    required this.onReset,
    required this.phaseContent,
  });

  final LanSyncViewState state;
  final bool receiving;
  final VoidCallback onCancel;
  final VoidCallback onReset;
  final List<Widget> Function(LanSyncViewState state) phaseContent;

  @override
  Widget build(BuildContext context) => LanSyncSheetFrame(
    title: receiving ? '接收临时数据' : '临时发送数据',
    description: receiving ? '已识别传输二维码，正在建立连接。' : '本次会发送书架、阅读进度和可传输的插件数据。',
    onClose: onCancel,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (state.phase == LanSyncPhase.idle || state.phase == LanSyncPhase.cancelled)
          const Center(
            child: Padding(padding: EdgeInsets.all(AppSpacing.regular), child: CircularProgressIndicator()),
          )
        else ...<Widget>[_StatusCard(state: state), const SizedBox(height: AppSpacing.regular), ...phaseContent(state)],
        if (state.phase == LanSyncPhase.completed || state.phase == LanSyncPhase.failed) ...<Widget>[
          const SizedBox(height: AppSpacing.regular),
          TextButton(onPressed: onReset, child: const Text('重新开始')),
        ],
      ],
    ),
  );
}

IconData _platformIcon(PairedDevicePlatform platform) => switch (platform) {
  PairedDevicePlatform.android => Icons.phone_android_rounded,
  PairedDevicePlatform.windows || PairedDevicePlatform.macos => Icons.computer_rounded,
  PairedDevicePlatform.unknown => Icons.devices_other_rounded,
};

String _relativeTime(DateTime value) {
  final delta = DateTime.now().toUtc().difference(value.toUtc());
  if (delta.inMinutes < 1) return '刚刚';
  if (delta.inHours < 1) return '${delta.inMinutes} 分钟前';
  if (delta.inDays < 1) return '${delta.inHours} 小时前';
  return '${delta.inDays} 天前';
}
