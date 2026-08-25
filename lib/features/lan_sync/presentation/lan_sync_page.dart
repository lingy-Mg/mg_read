import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_controller.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_qr_payload.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

class LanSyncPage extends ConsumerStatefulWidget {
  const LanSyncPage({
    required this.onBackRequested,
    required this.onDestinationRequested,
    super.key,
  });

  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;

  @override
  ConsumerState<LanSyncPage> createState() => _LanSyncPageState();
}

class _LanSyncPageState extends ConsumerState<LanSyncPage> {
  final TextEditingController _manualAddressController =
      TextEditingController();

  @override
  void dispose() {
    _manualAddressController.dispose();
    super.dispose();
  }

  Future<void> _back() async {
    await ref.read(lanSyncControllerProvider.notifier).cancel();
    if (mounted) widget.onBackRequested();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(lanSyncControllerProvider);
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
                AppSecondaryPageTopBar(
                  title: '局域网同步',
                  onBack: () => unawaited(_back()),
                  backButtonKey: const Key('lan-sync-back'),
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
                      const _TrustNotice(),
                      const SizedBox(height: AppSpacing.regular),
                      if (state.phase == LanSyncPhase.idle ||
                          state.phase == LanSyncPhase.cancelled)
                        _RoleChooser(
                          onSend: () => ref
                              .read(lanSyncControllerProvider.notifier)
                              .startSending(),
                          onReceive: () => ref
                              .read(lanSyncControllerProvider.notifier)
                              .startReceiving(),
                          onScan: _supportsQrScanner
                              ? () => unawaited(_scanAndReceive())
                              : null,
                        )
                      else ...<Widget>[
                        _StatusCard(state: state),
                        const SizedBox(height: AppSpacing.regular),
                        ..._phaseContent(state),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: AppBottomNavigation(
            selected: AppNavigationDestination.profile,
            onSelected: widget.onDestinationRequested,
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
        if (state.peers.isEmpty)
          const _HintCard(message: '暂未发现设备，可等待广播或手动输入发送端地址。'),
        for (final peer in state.peers)
          Card(
            child: ListTile(
              key: Key('lan-sync-peer-${peer.sessionId}'),
              leading: const Icon(Icons.devices_rounded),
              title: Text(peer.label),
              subtitle: Text(peer.endpoint),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => ref
                  .read(lanSyncControllerProvider.notifier)
                  .connectPeer(peer),
            ),
          ),
        const SizedBox(height: AppSpacing.regular),
        TextField(
          key: const Key('lan-sync-manual-address'),
          controller: _manualAddressController,
          decoration: const InputDecoration(
            labelText: '手动连接地址',
            hintText: '会话ID@192.168.1.2:端口',
            border: OutlineInputBorder(),
          ),
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
        FilledButton.icon(
          key: const Key('lan-sync-confirm-pairing'),
          onPressed: state.role == LanSyncRole.sender
              ? () => ref
                    .read(lanSyncControllerProvider.notifier)
                    .confirmSenderPairing()
              : () => ref
                    .read(lanSyncControllerProvider.notifier)
                    .confirmReceiverPairing(),
          icon: const Icon(Icons.check_circle_outline_rounded),
          label: const Text('两台设备显示一致，确认连接'),
        ),
        const SizedBox(height: AppSpacing.compact),
        _CancelButton(onPressed: _cancel),
      ],
      LanSyncPhase.previewing when state.preview != null => <Widget>[
        _PreviewSummary(state: state),
        const SizedBox(height: AppSpacing.regular),
        for (final conflict in state.preview!.conflicts)
          _ConflictCard(
            conflict: conflict,
            onChanged: (choice) => ref
                .read(lanSyncControllerProvider.notifier)
                .chooseConflict(conflict.identity, choice),
          ),
        FilledButton.icon(
          key: const Key('lan-sync-begin-import'),
          onPressed: () =>
              ref.read(lanSyncControllerProvider.notifier).beginImport(),
          icon: const Icon(Icons.sync_rounded),
          label: const Text('开始导入'),
        ),
        const SizedBox(height: AppSpacing.compact),
        _CancelButton(onPressed: _cancel),
      ],
      LanSyncPhase.preparing ||
      LanSyncPhase.previewing ||
      LanSyncPhase.transferring ||
      LanSyncPhase.applying => <Widget>[
        if (state.progress case final progress?)
          LinearProgressIndicator(
            key: const Key('lan-sync-progress'),
            value: progress,
          )
        else
          const LinearProgressIndicator(key: Key('lan-sync-progress')),
        const SizedBox(height: AppSpacing.regular),
        _CancelButton(onPressed: _cancel),
      ],
      LanSyncPhase.completed => <Widget>[
        if (state.result case final result?) _ResultCard(result: result),
        if (state.role == LanSyncRole.sender)
          const _HintCard(message: '接收设备正在完成本地安装与书架写入。'),
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
    ref
        .read(lanSyncControllerProvider.notifier)
        .connectManual(_manualAddressController.text);
  }

  bool get _supportsQrScanner =>
      defaultTargetPlatform == TargetPlatform.android;

  Future<void> _scanAndReceive({bool startDiscovery = true}) async {
    final notifier = ref.read(lanSyncControllerProvider.notifier);
    if (startDiscovery) {
      await notifier.startReceiving();
      if (!mounted ||
          ref.read(lanSyncControllerProvider).phase !=
              LanSyncPhase.discovering) {
        return;
      }
    }
    final payload = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => const _LanSyncQrScannerPage(),
      ),
    );
    if (!mounted || payload == null) return;
    final offer = LanSyncQrPayload.decode(payload);
    if (offer != null) await notifier.connectOffer(offer);
  }

  Future<void> _cancel() =>
      ref.read(lanSyncControllerProvider.notifier).cancel();
}

class _TrustNotice extends StatelessWidget {
  const _TrustNotice();

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.accentSoft,
        borderRadius: AppRadii.control,
        border: Border.all(color: tokens.divider),
      ),
      child: const Padding(
        padding: EdgeInsets.all(AppSpacing.regular),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.wifi_rounded),
            SizedBox(width: AppSpacing.compact),
            Expanded(
              child: Text('仅在可信的家庭或办公局域网使用。首版传输不加密，不会发送 Cookie、凭据、正文或封面文件。'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoleChooser extends StatelessWidget {
  const _RoleChooser({
    required this.onSend,
    required this.onReceive,
    this.onScan,
  });
  final VoidCallback onSend;
  final VoidCallback onReceive;
  final VoidCallback? onScan;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      _RoleCard(
        key: const Key('lan-sync-send'),
        icon: Icons.upload_rounded,
        title: '发送数据',
        description: '把本机已安装或正在开发的数据源、书架和阅读进度发送给另一台设备。',
        onTap: onSend,
      ),
      const SizedBox(height: AppSpacing.regular),
      _RoleCard(
        key: const Key('lan-sync-receive'),
        icon: Icons.download_rounded,
        title: '接收数据',
        description: '发现发送设备，预览插件版本和书架冲突后再导入。',
        onTap: onReceive,
      ),
      if (onScan != null) ...<Widget>[
        const SizedBox(height: AppSpacing.regular),
        _RoleCard(
          key: const Key('lan-sync-receive-qr'),
          icon: Icons.qr_code_scanner_rounded,
          title: '扫码接收',
          description: '扫描发送设备显示的二维码，直接建立局域网连接。',
          onTap: onScan!,
        ),
      ],
    ],
  );
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
    super.key,
  });
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      borderRadius: AppRadii.control,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.section),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 34),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.unit),
                  Text(description),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    ),
  );
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
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                state.phase == LanSyncPhase.completed
                    ? Icons.check_circle_rounded
                    : state.phase == LanSyncPhase.failed
                    ? Icons.error_outline_rounded
                    : Icons.sync_rounded,
              ),
        title: Text(state.message),
        subtitle: state.transferredBytes > 0
            ? Text('${_formatBytes(state.transferredBytes)} 已传输')
            : null,
      ),
    ),
  );
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
                        dataModuleStyle: QrDataModuleStyle(
                          color: colorScheme.onSurface,
                        ),
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
              child: Text(
                '手动连接地址',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            const SizedBox(height: AppSpacing.unit),
            if (value == null)
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('未找到可用的私有 IPv4 地址'),
              )
            else
              for (var index = 0; index < value.manualAddresses.length; index++)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: index == value.manualAddresses.length - 1
                          ? 0
                          : AppSpacing.unit,
                    ),
                    child: SelectableText(
                      value.manualAddresses[index],
                      key: Key(
                        index == 0
                            ? 'lan-sync-sender-address'
                            : 'lan-sync-sender-address-$index',
                      ),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _LanSyncQrScannerPage extends StatefulWidget {
  const _LanSyncQrScannerPage();

  @override
  State<_LanSyncQrScannerPage> createState() => _LanSyncQrScannerPageState();
}

class _LanSyncQrScannerPageState extends State<_LanSyncQrScannerPage> {
  late final MobileScannerController _controller = MobileScannerController(
    formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;
  String _message = '将发送端二维码放入取景框';

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final payload = barcode.rawValue;
      if (payload == null) continue;
      if (LanSyncQrPayload.decode(payload) == null) {
        if (mounted) setState(() => _message = '这不是 MgRead 局域网同步二维码');
        continue;
      }
      _handled = true;
      unawaited(_finish(payload));
      return;
    }
  }

  Future<void> _finish(String payload) async {
    await _controller.stop();
    if (mounted) Navigator.of(context).pop(payload);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫描同步二维码'),
        leading: IconButton(
          key: const Key('lan-sync-scanner-close'),
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
          tooltip: '关闭扫码',
        ),
      ),
      body: Semantics(
        label: '局域网同步二维码扫描器',
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            MobileScanner(
              key: const Key('lan-sync-qr-scanner'),
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (context, error) => ColoredBox(
                color: colorScheme.surface,
                child: const Center(child: Text('无法使用相机，请检查相机权限')),
              ),
            ),
            Center(
              child: IgnorePointer(
                child: Container(
                  width: 248,
                  height: 248,
                  decoration: BoxDecoration(
                    border: Border.all(color: colorScheme.primary, width: 3),
                    borderRadius: AppRadii.control,
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                minimum: const EdgeInsets.all(AppSpacing.regular),
                child: Card(
                  color: colorScheme.surface,
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.regular),
                    child: Text(_message, textAlign: TextAlign.center),
                  ),
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
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 5,
            ),
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
            Text('建议安装或升级：${preview.recommendedPluginIds.length} 个数据源'),
          ],
        ),
      ),
    );
  }
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
          Text(
            conflict.senderTitle,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: AppSpacing.unit),
          Text('本机：${conflict.localTitle}'),
          const SizedBox(height: AppSpacing.compact),
          DropdownButtonFormField<LanSyncConflictChoice>(
            key: Key('lan-sync-conflict-${conflict.identity.hashCode}'),
            initialValue: conflict.choice,
            decoration: const InputDecoration(
              labelText: '处理方式',
              border: OutlineInputBorder(),
            ),
            items: const <DropdownMenuItem<LanSyncConflictChoice>>[
              DropdownMenuItem(
                value: LanSyncConflictChoice.smartMerge,
                child: Text('智能合并'),
              ),
              DropdownMenuItem(
                value: LanSyncConflictChoice.useSender,
                child: Text('使用发送端'),
              ),
              DropdownMenuItem(
                value: LanSyncConflictChoice.keepLocal,
                child: Text('保留本机'),
              ),
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
          Text(
            '插件安装 ${result.pluginInstalled}，跳过 ${result.pluginSkipped}，失败 ${result.pluginFailed}',
          ),
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
    child: ListTile(
      leading: Icon(error ? Icons.error_outline_rounded : Icons.info_outline),
      title: Text(message),
    ),
  );
}

class _CancelButton extends StatelessWidget {
  const _CancelButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    key: const Key('lan-sync-cancel'),
    onPressed: onPressed,
    child: const Text('取消同步'),
  );
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}
