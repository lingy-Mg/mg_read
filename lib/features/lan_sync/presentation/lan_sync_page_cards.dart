/// 局域网同步主页的能力卡片与临时传输弹层。
///
/// 这些组件只呈现页面已经持有的状态和操作入口，不建立连接或修改传输协议。
part of 'lan_sync_page.dart';

class _DeviceSyncCard extends StatelessWidget {
  const _DeviceSyncCard({required this.state, required this.onAddDevice, required this.onManage, required this.onShowAll});

  final DeviceSyncState state;
  final VoidCallback onAddDevice;
  final ValueChanged<PairedDevice> onManage;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final displayed = state.devices.take(3).toList(growable: false);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: const BorderRadius.all(Radius.circular(18)),
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
                  onTap: () => onManage(device),
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
  const _DeviceSummaryTile({required this.device, required this.online, required this.busy, required this.onTap});

  final PairedDevice device;
  final bool online;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final status = busy
        ? '正在同步'
        : online
        ? '在线'
        : '离线';
    final detail = busy
        ? '正在处理同步内容'
        : device.lastSyncAtUtc == null
        ? (online ? '等待同步' : '打开另一台设备后可同步')
        : '最近同步：${_relativeTime(device.lastSyncAtUtc!)}';
    return InkWell(
      key: Key('device-sync-manage-${device.deviceId}'),
      borderRadius: AppRadii.detailControl,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.compact),
        child: Row(
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(color: online ? tokens.accentSoft : tokens.mutedSurface, borderRadius: AppRadii.detailControl),
              child: SizedBox.square(
                dimension: 42,
                child: Icon(_platformIcon(device.platform), color: online ? tokens.dataSourceAccent : tokens.mutedText),
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
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
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
        borderRadius: const BorderRadius.all(Radius.circular(18)),
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
                child: SizedBox.square(dimension: 44, child: Icon(icon, color: tokens.dataSourceAccent)),
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
              Text(actionLabel, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: tokens.dataSourceAccent)),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class _AllDevicesSheet extends StatelessWidget {
  const _AllDevicesSheet({required this.devices, required this.onlineDeviceIds, required this.onManage});

  final List<PairedDevice> devices;
  final Set<String> onlineDeviceIds;
  final ValueChanged<PairedDevice> onManage;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.comfortable, AppSpacing.compact, AppSpacing.comfortable, AppSpacing.comfortable),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('同步设备', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpacing.regular),
          for (final device in devices)
            _DeviceSummaryTile(
              device: device,
              online: onlineDeviceIds.contains(device.deviceId),
              busy: false,
              onTap: () => onManage(device),
            ),
        ],
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
