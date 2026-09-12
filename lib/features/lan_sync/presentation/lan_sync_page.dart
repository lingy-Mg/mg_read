/// 局域网同步设置页面。
///
/// 职责：
/// - 展示已配对设备、临时传输、连接、预览和导入阶段。
/// - 从统一扫码入口识别二维码类型，并路由至配对、数据接收或 App 获取。
/// - 在离开页面前取消进行中的同步操作。
///
/// 注意：
/// - 页面不显示主导航栏；它始终是“我的”下的子级页面。
/// - 临时数据和 App 传输分别由 LanSyncController、AppTransferController 管理；已配对设备由
///   DeviceSyncController 管理。
///
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/application/app_transfer_controller.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_controller.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/domain/app_transfer_qr_payload.dart';
import 'package:mg_read/features/lan_sync/domain/lan_pairing_payload.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_qr_payload.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

import 'lan_sync_qr_scanner_page.dart';
import 'lan_sync_overview_widgets.dart';
import 'lan_sync_sheet_widgets.dart';
import 'paired_device_widgets.dart';
import 'app_transfer_widgets.dart';

part 'lan_sync_app_transfer_actions.dart';
part 'lan_sync_page_cards.dart';
part 'lan_sync_status_widgets.dart';

class LanSyncPage extends ConsumerStatefulWidget {
  const LanSyncPage({required this.onBackRequested, required this.onDestinationRequested, super.key});

  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;

  @override
  ConsumerState<LanSyncPage> createState() => _LanSyncPageState();
}

class _LanSyncPageState extends ConsumerState<LanSyncPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(deviceSyncControllerProvider.notifier).start());
    });
  }

  Future<void> _back() async {
    await ref.read(deviceSyncControllerProvider.notifier).cancelPairing();
    await ref.read(lanSyncControllerProvider.notifier).cancel();
    await ref.read(appTransferControllerProvider.notifier).cancel();
    if (mounted) widget.onBackRequested();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(lanSyncControllerProvider);
    final appState = ref.watch(appTransferControllerProvider);
    final deviceState = ref.watch(deviceSyncControllerProvider);
    final tokens = AppThemeTokens.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_back());
      },
      child: Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[tokens.pageBackground, const Color(0xFFFFFCF9), tokens.pageBackground],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: AppSecondaryPageContent(
              child: Column(
                children: <Widget>[
                  AppSecondaryPageTopBar(
                    title: '局域网同步',
                    onBack: () => unawaited(_back()),
                    backButtonKey: const Key('lan-sync-back'),
                    actions: <Widget>[
                      AppSecondaryPageIconButton(
                        key: const Key('lan-sync-scan'),
                        label: '扫码',
                        icon: Icons.qr_code_scanner_rounded,
                        onPressed: () => unawaited(_scanAndRoute()),
                      ),
                    ],
                  ),
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
                        LanSyncOverviewCard(networkReady: deviceState.started),
                        const SizedBox(height: AppSpacing.section),
                        _DeviceSyncCard(
                          state: deviceState,
                          onAddDevice: _showAddDeviceSheet,
                          onManage: _manageDevice,
                          onShowAll: _showAllDevicesSheet,
                        ),
                        const SizedBox(height: AppSpacing.section),
                        _CapabilityCard(
                          key: const Key('lan-sync-send-app'),
                          icon: Icons.mobile_friendly_rounded,
                          title: '发送 App',
                          description: '将当前 App 安装包发送给局域网中的其他设备',
                          actionLabel: '发送 App',
                          onTap: appState.active ? null : _showAppTransferSheet,
                        ),
                        const SizedBox(height: AppSpacing.regular),
                        _CapabilityCard(
                          key: const Key('lan-sync-temporary-transfer'),
                          icon: Icons.send_to_mobile_rounded,
                          title: '临时发送',
                          description: '发送一次书架和插件数据，不建立长期同步关系',
                          actionLabel: '发送数据',
                          onTap: state.busy ? null : _showTemporarySendSheet,
                        ),
                        const SizedBox(height: AppSpacing.section),
                        const LanSyncTipsCard(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _phaseContent(LanSyncViewState state) {
    return switch (state.phase) {
      LanSyncPhase.discovering => <Widget>[
        const _HintCard(message: '请扫描发送设备显示的二维码，局域网内不会自动发现或广播设备。'),
        if (_supportsQrScanner) ...<Widget>[
          const SizedBox(height: AppSpacing.regular),
          FilledButton.icon(
            key: const Key('lan-sync-scan-qr'),
            onPressed: () => unawaited(_scanAndRoute()),
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('扫描二维码'),
          ),
        ],
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
        LanSyncContentSelection(
          manifest: state.manifest!,
          preview: state.preview!,
          onSelectAll: (selected) => ref.read(lanSyncControllerProvider.notifier).chooseAllContent(selected),
          onSelectAllShelfItems: (selected) => ref.read(lanSyncControllerProvider.notifier).chooseAllShelfItems(selected),
          onSelectAllPlugins: (selected) => ref.read(lanSyncControllerProvider.notifier).chooseAllPlugins(selected),
          onPluginChanged: (pluginId, selected) => ref.read(lanSyncControllerProvider.notifier).choosePlugin(pluginId, selected),
          onShelfItemChanged: (identity, selected) => ref.read(lanSyncControllerProvider.notifier).chooseShelfItem(identity, selected),
        ),
        const SizedBox(height: AppSpacing.regular),
        for (final conflict in state.preview!.conflicts) _ConflictCard(conflict: conflict),
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

  bool get _supportsQrScanner => defaultTargetPlatform == TargetPlatform.android;

  Future<void> _scanAndRoute() async {
    final payload = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute<String>(fullscreenDialog: true, builder: (_) => const LanSyncQrScannerPage()));
    if (!mounted || payload == null) return;

    final pairingOffer = LanPairingQrPayload.decode(payload);
    if (pairingOffer != null) {
      unawaited(ref.read(deviceSyncControllerProvider.notifier).joinPairing(payload));
      if (mounted) await _showAddDeviceSheet(beginPairing: false);
      return;
    }

    final syncOffer = LanSyncQrPayload.decode(payload);
    if (syncOffer != null) {
      unawaited(_receiveScannedData(syncOffer));
      if (mounted) await _showTemporaryDataSheet(receiving: true);
      return;
    }

    final appOffer = AppTransferQrPayload.decode(payload);
    if (appOffer != null) await _connectScannedAppOffer(appOffer);
  }

  Future<void> _manageDevice(PairedDevice device) async {
    await showModalBottomSheet<void>(
      context: context,
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
    showDragHandle: true,
    builder: (sheetContext) {
      final state = ref.read(deviceSyncControllerProvider);
      return _AllDevicesSheet(
        devices: state.devices,
        onlineDeviceIds: state.onlineDeviceIds,
        onManage: (device) {
          Navigator.of(sheetContext).pop();
          unawaited(_manageDevice(device));
        },
      );
    },
  );

  Future<void> _showAppTransferSheet() async {
    unawaited(ref.read(appTransferControllerProvider.notifier).startSending());
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => Consumer(
        builder: (context, ref, _) {
          final appState = ref.watch(appTransferControllerProvider);
          return LanSyncSheetFrame(
            title: '发送 App',
            description: '生成二维码后，对方使用“扫码连接 / 接收”即可继续。',
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
    if (mounted && ref.read(appTransferControllerProvider).active) await ref.read(appTransferControllerProvider.notifier).cancel();
  }

  Future<void> _showTemporarySendSheet() {
    unawaited(ref.read(lanSyncControllerProvider.notifier).startSending());
    return _showTemporaryDataSheet(receiving: false);
  }

  Future<void> _showTemporaryDataSheet({required bool receiving}) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => Consumer(
        builder: (context, ref, _) => _TemporaryDataSheet(
          state: ref.watch(lanSyncControllerProvider),
          receiving: receiving,
          onCancel: () {
            unawaited(ref.read(lanSyncControllerProvider.notifier).cancel());
            Navigator.of(sheetContext).pop();
          },
          onReset: () => ref.read(lanSyncControllerProvider.notifier).reset(),
          phaseContent: _phaseContent,
        ),
      ),
    );
    if (mounted && ref.read(lanSyncControllerProvider).busy) await ref.read(lanSyncControllerProvider.notifier).cancel();
  }

  Future<void> _receiveScannedData(LanSyncConnectionOffer offer) async {
    final notifier = ref.read(lanSyncControllerProvider.notifier);
    await notifier.startReceiving();
    if (mounted && ref.read(lanSyncControllerProvider).phase == LanSyncPhase.discovering) await notifier.connectOffer(offer);
  }

  Future<void> _cancel() => ref.read(lanSyncControllerProvider.notifier).cancel();
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
                '请使用接收设备扫描二维码。二维码包含 ${value.addresses.length} 个可用局域网地址。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.regular),
            ],
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

/// 临时同步预览中的内容选择器。
///
/// 总选择和分组选择都按当前聚合状态切换：已全选时清空，未全选时补齐全选。
class LanSyncContentSelection extends StatelessWidget {
  const LanSyncContentSelection({
    required this.manifest,
    required this.preview,
    required this.onSelectAll,
    required this.onSelectAllShelfItems,
    required this.onSelectAllPlugins,
    required this.onPluginChanged,
    required this.onShelfItemChanged,
    super.key,
  });

  final LanSyncManifest manifest;
  final LanSyncImportPreview preview;
  final ValueChanged<bool> onSelectAll;
  final ValueChanged<bool> onSelectAllShelfItems;
  final ValueChanged<bool> onSelectAllPlugins;
  final void Function(String pluginId, bool selected) onPluginChanged;
  final void Function(String identity, bool selected) onShelfItemChanged;

  @override
  Widget build(BuildContext context) {
    final selectablePluginCount = manifest.plugins.where((plugin) => _isSelectablePlugin(plugin, preview)).length;
    final selectedCount = preview.selectedPluginIds.length + preview.selectedShelfItemIds.length;
    final totalCount = selectablePluginCount + manifest.shelfItems.length;
    final allSelected = totalCount > 0 && selectedCount == totalCount;
    final noneSelected = selectedCount == 0;
    final selectableShelfIds = <String>{for (final item in manifest.shelfItems) item.identity};
    final selectablePluginIds = <String>{
      for (final plugin in manifest.plugins)
        if (_isSelectablePlugin(plugin, preview)) plugin.id,
    };
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
              onChanged: (_) => onSelectAll(!allSelected),
              title: Text('全选同步内容（$selectedCount/$totalCount）'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            if (manifest.shelfItems.isNotEmpty) ...<Widget>[
              const Divider(height: 1),
              _SelectionSectionTitle(
                key: const Key('lan-sync-select-all-shelf'),
                label: '书架内容',
                selectedCount: preview.selectedShelfItemIds.length,
                totalCount: selectableShelfIds.length,
                value: _selectionValue(preview.selectedShelfItemIds, selectableShelfIds),
                onChanged: onSelectAllShelfItems,
              ),
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
              _SelectionSectionTitle(
                key: const Key('lan-sync-select-all-plugins'),
                label: '数据源插件',
                selectedCount: preview.selectedPluginIds.length,
                totalCount: selectablePluginIds.length,
                value: _selectionValue(preview.selectedPluginIds, selectablePluginIds),
                onChanged: onSelectAllPlugins,
              ),
              for (final plugin in manifest.plugins)
                _PluginSelectionTile(
                  key: Key('lan-sync-plugin-${plugin.id}'),
                  plugin: plugin,
                  plan: preview.pluginPlans[plugin.id],
                  selected: preview.selectedPluginIds.contains(plugin.id),
                  onChanged: _isSelectablePlugin(plugin, preview) ? (selected) => onPluginChanged(plugin.id, selected) : null,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SelectionSectionTitle extends StatelessWidget {
  const _SelectionSectionTitle({
    required this.label,
    required this.selectedCount,
    required this.totalCount,
    required this.value,
    required this.onChanged,
    super.key,
  });
  final String label;
  final int selectedCount;
  final int totalCount;
  final bool? value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
    value: value,
    tristate: true,
    onChanged: (_) => onChanged(value != true),
    title: Text('$label（$selectedCount/$totalCount）', style: Theme.of(context).textTheme.labelLarge),
    controlAffinity: ListTileControlAffinity.leading,
    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.regular),
    dense: true,
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
    LanSyncPluginPlanState.developmentConflict => '本机有开发构建，将强制覆盖',
    LanSyncPluginPlanState.missing => '缺少，将安装',
    LanSyncPluginPlanState.upgrade => '将覆盖本机版本',
    LanSyncPluginPlanState.sameVersion => '版本相同，可强制覆盖',
    LanSyncPluginPlanState.receiverNewer => '本机版本较新，仍将覆盖',
    LanSyncPluginPlanState.unavailable || null => '没有可传输文件',
  };
  final build = plugin.provenance == LanSyncPluginProvenance.development
      ? '开发构建 ${plugin.developmentRevision}'
      : plugin.provenance == LanSyncPluginProvenance.developmentReplica
      ? '开发副本 ${plugin.developmentRevision}'
      : plugin.version;
  return '$planText · $build';
}

bool _isSelectablePlugin(LanSyncPluginDescriptor plugin, LanSyncImportPreview preview) {
  if (!plugin.transferable) return false;
  final plan = preview.pluginPlans[plugin.id];
  return plan == LanSyncPluginPlanState.missing ||
      plan == LanSyncPluginPlanState.upgrade ||
      (plan == LanSyncPluginPlanState.sameVersion && plugin.provenance == LanSyncPluginProvenance.installed);
}

bool? _selectionValue(Set<String> selected, Set<String> selectable) {
  if (selectable.isEmpty || selected.isEmpty) return false;
  if (selectable.every(selected.contains)) return true;
  return null;
}

class _ConflictCard extends StatelessWidget {
  const _ConflictCard({required this.conflict});
  final LanSyncBookConflict conflict;

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
          const Text('强制覆盖：使用发送端的书架信息和阅读进度。'),
          const SizedBox(height: AppSpacing.unit),
          const Text('本机对应条目会被发送端内容替换。'),
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
