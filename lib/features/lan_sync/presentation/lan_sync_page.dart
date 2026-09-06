/// 局域网同步设置页面。
///
/// 职责：
/// - 展示同步角色、连接、预览和导入阶段。
/// - 在离开页面前取消进行中的同步操作。
///
/// 注意：
/// - 页面不显示主导航栏；它始终是“我的”下的子级页面。
/// - 临时传输由 LanSyncController 管理；已配对设备、自动发现和手动同步/拉取/推送由 DeviceSyncController 管理。
///
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_controller.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_qr_payload.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

import 'lan_sync_qr_scanner_page.dart';
import 'lan_sync_overview_widgets.dart';
import 'paired_device_widgets.dart';

class LanSyncPage extends ConsumerStatefulWidget {
  const LanSyncPage({required this.onBackRequested, required this.onDestinationRequested, super.key});

  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;

  @override
  ConsumerState<LanSyncPage> createState() => _LanSyncPageState();
}

class _LanSyncPageState extends ConsumerState<LanSyncPage> {
  final TextEditingController _manualAddressController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(deviceSyncControllerProvider.notifier).start());
    });
  }

  @override
  void dispose() {
    _manualAddressController.dispose();
    super.dispose();
  }

  Future<void> _back() async {
    await ref.read(deviceSyncControllerProvider.notifier).cancelPairing();
    await ref.read(lanSyncControllerProvider.notifier).cancel();
    if (mounted) widget.onBackRequested();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(lanSyncControllerProvider);
    final deviceState = ref.watch(deviceSyncControllerProvider);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_back());
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: AppSecondaryPageContent(
            child: Column(
              children: <Widget>[
                AppSecondaryPageTopBar(title: '局域网同步', onBack: () => unawaited(_back()), backButtonKey: const Key('lan-sync-back')),
                Expanded(
                  child: ListView(
                    key: const Key('lan-sync-content'),
                    padding: const EdgeInsets.fromLTRB(
                      AppDetailMetrics.horizontalPadding,
                      AppSpacing.compact,
                      AppDetailMetrics.horizontalPadding,
                      AppSpacing.page,
                    ),
                    children: <Widget>[
                      const LanSyncOverviewCard(),
                      const SizedBox(height: AppSpacing.regular),
                      PairedDevicesSection(
                        state: deviceState,
                        supportsScanner: _supportsQrScanner,
                        onBeginPairing: () => ref.read(deviceSyncControllerProvider.notifier).beginPairing(),
                        onScanPairing: _supportsQrScanner ? () => unawaited(_scanAndPair()) : null,
                        onApprovePairing: () => ref.read(deviceSyncControllerProvider.notifier).approvePairing(),
                        onRejectPairing: () => ref.read(deviceSyncControllerProvider.notifier).rejectPairing(),
                        onCancelPairing: () => ref.read(deviceSyncControllerProvider.notifier).cancelPairing(),
                        onSync: (deviceId, operation) =>
                            ref.read(deviceSyncControllerProvider.notifier).syncNow(deviceId, operation: operation),
                        onManage: _manageDevice,
                      ),
                      const SizedBox(height: AppSpacing.regular),
                      if (state.phase == LanSyncPhase.idle || state.phase == LanSyncPhase.cancelled)
                        Column(
                          key: const Key('lan-sync-temporary-transfer'),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Text('临时传输', style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: AppSpacing.unit),
                            Text('用于尚未配对的设备；仅本次有效，需要发送端保持页面并核对确认码。', style: Theme.of(context).textTheme.bodySmall),
                            const SizedBox(height: AppSpacing.regular),
                            LanSyncRoleChooser(
                              onSend: () => ref.read(lanSyncControllerProvider.notifier).startSending(),
                              onReceive: () => ref.read(lanSyncControllerProvider.notifier).startReceiving(),
                              onScan: _supportsQrScanner ? () => unawaited(_scanAndReceive()) : null,
                            ),
                          ],
                        )
                      else ...<Widget>[_StatusCard(state: state), const SizedBox(height: AppSpacing.regular), ..._phaseContent(state)],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _phaseContent(LanSyncViewState state) {
    return switch (state.phase) {
      LanSyncPhase.discovering => <Widget>[
        if (_supportsQrScanner) ...<Widget>[
          FilledButton.icon(
            key: const Key('lan-sync-scan-qr'),
            onPressed: () => unawaited(_scanAndReceive(startDiscovery: false)),
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('扫描发送端二维码'),
          ),
          const SizedBox(height: AppSpacing.regular),
        ],
        if (state.peers.isEmpty) const _HintCard(message: '暂未发现设备，可等待广播或手动输入发送端地址。'),
        for (final peer in state.peers)
          Card(
            child: ListTile(
              key: Key('lan-sync-peer-${peer.sessionId}'),
              leading: const Icon(Icons.devices_rounded),
              title: Text(peer.label),
              subtitle: Text(peer.endpoint),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => ref.read(lanSyncControllerProvider.notifier).connectPeer(peer),
            ),
          ),
        const SizedBox(height: AppSpacing.regular),
        TextField(
          key: const Key('lan-sync-manual-address'),
          controller: _manualAddressController,
          decoration: const InputDecoration(labelText: '手动连接地址', hintText: '会话ID@192.168.1.2:端口', border: OutlineInputBorder()),
          autocorrect: false,
          enableSuggestions: false,
          onSubmitted: (_) => _connectManual(),
        ),
        const SizedBox(height: AppSpacing.compact),
        FilledButton.tonalIcon(
          key: const Key('lan-sync-connect-manual'),
          onPressed: _connectManual,
          icon: const Icon(Icons.link_rounded),
          label: const Text('连接'),
        ),
      ],
      LanSyncPhase.waitingForPeer => <Widget>[
        LanSyncConnectionQrCard(offer: state.connectionOffer),
        const SizedBox(height: AppSpacing.regular),
        const _HintCard(message: '保持本页打开。若 Windows 防火墙询问，请只允许专用网络访问。'),
        const SizedBox(height: AppSpacing.regular),
        _CancelButton(onPressed: _cancel),
      ],
      LanSyncPhase.pairing => <Widget>[
        _PairingCard(code: state.pairingCode ?? '------'),
        const SizedBox(height: AppSpacing.regular),
        if (state.role == LanSyncRole.receiver)
          FilledButton.icon(
            key: const Key('lan-sync-confirm-pairing'),
            onPressed: () => ref.read(lanSyncControllerProvider.notifier).confirmReceiverPairing(),
            icon: const Icon(Icons.check_circle_outline_rounded),
            label: const Text('确认连接并查看同步内容'),
          )
        else
          const _HintCard(message: '发送方无需确认，等待接收方核对确认码并选择内容。'),
        const SizedBox(height: AppSpacing.compact),
        _CancelButton(onPressed: _cancel),
      ],
      LanSyncPhase.previewing when state.preview != null => <Widget>[
        _PreviewSummary(state: state),
        const SizedBox(height: AppSpacing.regular),
        _SyncContentSelection(
          manifest: state.manifest!,
          preview: state.preview!,
          onSelectAll: (selected) => ref.read(lanSyncControllerProvider.notifier).chooseAllContent(selected),
          onPluginChanged: (pluginId, selected) => ref.read(lanSyncControllerProvider.notifier).choosePlugin(pluginId, selected),
          onShelfItemChanged: (identity, selected) => ref.read(lanSyncControllerProvider.notifier).chooseShelfItem(identity, selected),
        ),
        const SizedBox(height: AppSpacing.regular),
        for (final conflict in state.preview!.conflicts)
          _ConflictCard(
            conflict: conflict,
            onChanged: (choice) => ref.read(lanSyncControllerProvider.notifier).chooseConflict(conflict.identity, choice),
          ),
        FilledButton.icon(
          key: const Key('lan-sync-begin-import'),
          onPressed: state.preview!.hasSelection ? () => ref.read(lanSyncControllerProvider.notifier).beginImport() : null,
          icon: const Icon(Icons.sync_rounded),
          label: const Text('开始导入'),
        ),
        const SizedBox(height: AppSpacing.compact),
        _CancelButton(onPressed: _cancel),
      ],
      LanSyncPhase.preparing || LanSyncPhase.previewing || LanSyncPhase.transferring || LanSyncPhase.applying => <Widget>[
        if (state.progress case final progress?)
          LinearProgressIndicator(key: const Key('lan-sync-progress'), value: progress)
        else
          const LinearProgressIndicator(key: Key('lan-sync-progress')),
        const SizedBox(height: AppSpacing.regular),
        _CancelButton(onPressed: _cancel),
      ],
      LanSyncPhase.completed => <Widget>[
        if (state.result case final result?) _ResultCard(result: result),
        if (state.role == LanSyncRole.sender) const _HintCard(message: '接收设备正在完成本地安装与书架写入。'),
        const SizedBox(height: AppSpacing.regular),
        FilledButton(
          key: const Key('lan-sync-finish'),
          onPressed: () => ref.read(lanSyncControllerProvider.notifier).reset(),
          child: const Text('完成'),
        ),
      ],
      LanSyncPhase.failed => <Widget>[
        _HintCard(message: state.message, error: true),
        const SizedBox(height: AppSpacing.regular),
        FilledButton(
          key: const Key('lan-sync-retry'),
          onPressed: () => ref.read(lanSyncControllerProvider.notifier).reset(),
          child: const Text('返回重新选择'),
        ),
      ],
      _ => const <Widget>[],
    };
  }

  void _connectManual() {
    ref.read(lanSyncControllerProvider.notifier).connectManual(_manualAddressController.text);
  }

  bool get _supportsQrScanner => defaultTargetPlatform == TargetPlatform.android;

  Future<void> _scanAndReceive({bool startDiscovery = true}) async {
    final notifier = ref.read(lanSyncControllerProvider.notifier);
    if (startDiscovery) {
      await notifier.startReceiving();
      if (!mounted || ref.read(lanSyncControllerProvider).phase != LanSyncPhase.discovering) {
        return;
      }
    }
    final payload = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute<String>(fullscreenDialog: true, builder: (_) => const LanSyncQrScannerPage()));
    if (!mounted || payload == null) return;
    final offer = LanSyncQrPayload.decode(payload);
    if (offer != null) await notifier.connectOffer(offer);
  }

  Future<void> _scanAndPair() async {
    final payload = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => const LanSyncQrScannerPage(purpose: LanSyncQrScannerPurpose.pairing),
      ),
    );
    if (!mounted || payload == null) return;
    await ref.read(deviceSyncControllerProvider.notifier).joinPairing(payload);
  }

  Future<void> _manageDevice(PairedDevice device) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DeviceSettingsSheet(deviceId: device.deviceId),
    );
  }

  Future<void> _cancel() => ref.read(lanSyncControllerProvider.notifier).cancel();
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state});
  final LanSyncViewState state;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Card(
      child: ListTile(
        leading: state.busy
            ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(
                state.phase == LanSyncPhase.completed
                    ? Icons.check_circle_rounded
                    : state.phase == LanSyncPhase.failed
                    ? Icons.error_outline_rounded
                    : Icons.sync_rounded,
              ),
        title: Text(state.message),
        subtitle: _StatusDetail(state: state),
      ),
    ),
  );
}

class _StatusDetail extends StatelessWidget {
  const _StatusDetail({required this.state});

  final LanSyncViewState state;

  @override
  Widget build(BuildContext context) {
    final transferred = state.transferredBytes > 0 ? '${_formatBytes(state.transferredBytes)} 已接收' : null;
    final detail = switch (state.message) {
      '正在传输插件' => '正在从发送端接收插件文件。',
      '正在校验并保存插件' => '文件已到齐，正在校验完整性并写入受控入箱。',
      '正在完成插件安装' => '正在让数据源 Runtime 冷启动并确认插件可用。',
      '正在写入书架和阅读进度' => '插件已处理，正在单事务写入选中的书架和进度。',
      _ => null,
    };
    if (transferred == null && detail == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[if (transferred != null) Text(transferred), if (detail != null) Text(detail)],
    );
  }
}

class LanSyncConnectionQrCard extends StatelessWidget {
  const LanSyncConnectionQrCard({required this.offer, super.key});
  final LanSyncConnectionOffer? offer;

  @override
  Widget build(BuildContext context) {
    final value = offer;
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: Column(
          children: <Widget>[
            Text('用接收设备扫码连接', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.regular),
            if (value != null)
              Semantics(
                image: true,
                label: 'MgRead 局域网同步二维码',
                child: ExcludeSemantics(
                  child: ColoredBox(
                    color: colorScheme.surface,
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.compact),
                      child: QrImageView(
                        key: const Key('lan-sync-sender-qr'),
                        data: LanSyncQrPayload.encode(value),
                        version: QrVersions.auto,
                        size: 220,
                        backgroundColor: colorScheme.surface,
                        eyeStyle: QrEyeStyle(color: colorScheme.onSurface),
                        dataModuleStyle: QrDataModuleStyle(color: colorScheme.onSurface),
                      ),
                    ),
                  ),
                ),
              )
            else
              const Text('未找到可用的私有 IPv4 地址'),
            const SizedBox(height: AppSpacing.regular),
            if (value != null) ...<Widget>[
              Text(
                '二维码包含 ${value.addresses.length} 个可用地址，接收端会并发测试并自动选择。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.regular),
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: Text('手动连接地址', style: Theme.of(context).textTheme.labelLarge),
            ),
            const SizedBox(height: AppSpacing.unit),
            if (value == null)
              const Align(alignment: Alignment.centerLeft, child: Text('未找到可用的私有 IPv4 地址'))
            else
              for (var index = 0; index < value.manualAddresses.length; index++)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: index == value.manualAddresses.length - 1 ? 0 : AppSpacing.unit),
                    child: SelectableText(
                      value.manualAddresses[index],
                      key: Key(index == 0 ? 'lan-sync-sender-address' : 'lan-sync-sender-address-$index'),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _PairingCard extends StatelessWidget {
  const _PairingCard({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.section),
      child: Column(
        children: <Widget>[
          const Text('两台设备应显示相同的确认码'),
          const SizedBox(height: AppSpacing.regular),
          Text(
            code,
            key: const Key('lan-sync-pairing-code'),
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 5),
          ),
        ],
      ),
    ),
  );
}

class _PreviewSummary extends StatelessWidget {
  const _PreviewSummary({required this.state});
  final LanSyncViewState state;

  @override
  Widget build(BuildContext context) {
    final preview = state.preview!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('导入预览', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.compact),
            Text('新增书架：${preview.newItemCount} 本'),
            Text('需要确认：${preview.conflicts.length} 本'),
            Text('缺少可用数据源：${preview.blockedItemCount} 本'),
            Text('已选择：${preview.selectedShelfItemIds.length} 本书，${preview.selectedPluginIds.length} 个数据源'),
          ],
        ),
      ),
    );
  }
}

class _SyncContentSelection extends StatelessWidget {
  const _SyncContentSelection({
    required this.manifest,
    required this.preview,
    required this.onSelectAll,
    required this.onPluginChanged,
    required this.onShelfItemChanged,
  });

  final LanSyncManifest manifest;
  final LanSyncImportPreview preview;
  final ValueChanged<bool> onSelectAll;
  final void Function(String pluginId, bool selected) onPluginChanged;
  final void Function(String identity, bool selected) onShelfItemChanged;

  @override
  Widget build(BuildContext context) {
    final selectablePluginCount = preview.recommendedPluginIds.length;
    final selectedCount = preview.selectedPluginIds.length + preview.selectedShelfItemIds.length;
    final totalCount = selectablePluginCount + manifest.shelfItems.length;
    final allSelected = totalCount > 0 && selectedCount == totalCount;
    final noneSelected = selectedCount == 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.compact),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.regular),
              child: Text('选择同步内容'),
            ),
            CheckboxListTile(
              key: const Key('lan-sync-select-all'),
              value: allSelected
                  ? true
                  : noneSelected
                  ? false
                  : null,
              tristate: true,
              onChanged: (value) => onSelectAll(value != true),
              title: Text('全选同步内容（$selectedCount/$totalCount）'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            if (manifest.shelfItems.isNotEmpty) ...<Widget>[
              const Divider(height: 1),
              _SelectionSectionTitle(label: '书架内容'),
              for (var index = 0; index < manifest.shelfItems.length; index++)
                _ShelfSelectionTile(
                  key: Key('lan-sync-shelf-item-$index'),
                  item: manifest.shelfItems[index],
                  selected: preview.selectedShelfItemIds.contains(manifest.shelfItems[index].identity),
                  onChanged: (selected) => onShelfItemChanged(manifest.shelfItems[index].identity, selected),
                ),
            ],
            if (manifest.plugins.isNotEmpty) ...<Widget>[
              const Divider(height: 1),
              _SelectionSectionTitle(label: '数据源插件'),
              for (final plugin in manifest.plugins)
                _PluginSelectionTile(
                  key: Key('lan-sync-plugin-${plugin.id}'),
                  plugin: plugin,
                  plan: preview.pluginPlans[plugin.id],
                  selected: preview.selectedPluginIds.contains(plugin.id),
                  onChanged: preview.recommendedPluginIds.contains(plugin.id) ? (selected) => onPluginChanged(plugin.id, selected) : null,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SelectionSectionTitle extends StatelessWidget {
  const _SelectionSectionTitle({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(AppSpacing.regular, AppSpacing.compact, AppSpacing.regular, AppSpacing.unit),
    child: Text(label, style: Theme.of(context).textTheme.labelLarge),
  );
}

class _ShelfSelectionTile extends StatelessWidget {
  const _ShelfSelectionTile({required this.item, required this.selected, required this.onChanged, super.key});
  final LanSyncShelfItem item;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
    value: selected,
    onChanged: (value) {
      if (value != null) onChanged(value);
    },
    title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text(item.author ?? item.sourceName ?? '书架内容'),
    controlAffinity: ListTileControlAffinity.leading,
  );
}

class _PluginSelectionTile extends StatelessWidget {
  const _PluginSelectionTile({required this.plugin, required this.plan, required this.selected, required this.onChanged, super.key});
  final LanSyncPluginDescriptor plugin;
  final LanSyncPluginPlanState? plan;
  final bool selected;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
    value: onChanged == null ? false : selected,
    onChanged: onChanged == null
        ? null
        : (value) {
            if (value != null) onChanged!(value);
          },
    title: Text(plugin.displayName ?? plugin.id, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text(_pluginSelectionDescription(plugin, plan)),
    controlAffinity: ListTileControlAffinity.leading,
  );
}

String _pluginSelectionDescription(LanSyncPluginDescriptor plugin, LanSyncPluginPlanState? plan) {
  final planText = switch (plan) {
    LanSyncPluginPlanState.developmentConflict => '本机有开发构建，优先保留并跳过同步',
    LanSyncPluginPlanState.missing => '缺少，将安装',
    LanSyncPluginPlanState.upgrade => '可升级',
    LanSyncPluginPlanState.sameVersion => '版本相同，跳过',
    LanSyncPluginPlanState.receiverNewer => '本机版本较新，跳过',
    LanSyncPluginPlanState.unavailable || null => '没有可传输文件',
  };
  final build = plugin.provenance == LanSyncPluginProvenance.development
      ? '开发构建 ${plugin.developmentRevision}'
      : plugin.provenance == LanSyncPluginProvenance.developmentReplica
      ? '开发副本 ${plugin.developmentRevision}'
      : plugin.version;
  return '$planText · $build';
}

class _ConflictCard extends StatelessWidget {
  const _ConflictCard({required this.conflict, required this.onChanged});
  final LanSyncBookConflict conflict;
  final ValueChanged<LanSyncConflictChoice> onChanged;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.regular),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(conflict.senderTitle, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.unit),
          Text('本机：${conflict.localTitle}'),
          const SizedBox(height: AppSpacing.compact),
          DropdownButtonFormField<LanSyncConflictChoice>(
            key: Key('lan-sync-conflict-${conflict.identity.hashCode}'),
            initialValue: conflict.choice,
            decoration: const InputDecoration(labelText: '处理方式', border: OutlineInputBorder()),
            items: const <DropdownMenuItem<LanSyncConflictChoice>>[
              DropdownMenuItem(value: LanSyncConflictChoice.smartMerge, child: Text('智能合并')),
              DropdownMenuItem(value: LanSyncConflictChoice.useSender, child: Text('使用发送端')),
              DropdownMenuItem(value: LanSyncConflictChoice.keepLocal, child: Text('保留本机')),
            ],
            onChanged: (value) {
              if (value != null) onChanged(value);
            },
          ),
          const SizedBox(height: AppSpacing.unit),
          const Text('智能合并会采用发送端展示信息，并保留更新时间较新的阅读进度。'),
        ],
      ),
    ),
  );
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});
  final LanSyncApplyResult result;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.regular),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('同步结果', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.compact),
          Text('书架新增 ${result.added}，更新 ${result.updated}'),
          Text('保留本机 ${result.keptLocal}，无法导入 ${result.blocked}'),
          Text('插件安装 ${result.pluginInstalled}，跳过 ${result.pluginSkipped}，失败 ${result.pluginFailed}'),
        ],
      ),
    ),
  );
}

class _HintCard extends StatelessWidget {
  const _HintCard({required this.message, this.error = false});
  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(leading: Icon(error ? Icons.error_outline_rounded : Icons.info_outline), title: Text(message)),
  );
}

class _CancelButton extends StatelessWidget {
  const _CancelButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(key: const Key('lan-sync-cancel'), onPressed: onPressed, child: const Text('取消同步'));
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}
