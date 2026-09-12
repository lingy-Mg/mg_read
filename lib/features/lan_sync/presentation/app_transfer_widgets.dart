/// 临时 App 发送/获取入口与版本确认面板。
///
/// 只投影视图状态和点击意图；HTTP 会话、包校验与安装生命周期由控制器持有。
library;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/application/app_transfer_controller.dart';
import 'package:mg_read/features/lan_sync/domain/app_transfer_qr_payload.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';

class AppTransferRoleChooser extends StatelessWidget {
  const AppTransferRoleChooser({required this.onSend, required this.onReceive, super.key});

  final VoidCallback onSend;
  final VoidCallback onReceive;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final cards = <Widget>[
        _AppRoleCard(
          key: const Key('app-transfer-send'),
          icon: Icons.mobile_friendly_rounded,
          title: '发送 App',
          description: '把本机安装包提供给相同平台的设备',
          onTap: onSend,
        ),
        _AppRoleCard(
          key: const Key('app-transfer-receive'),
          icon: Icons.system_update_alt_rounded,
          title: '获取 App',
          description: '扫描发送端二维码，比较版本后选择升级或强制安装',
          onTap: onReceive,
        ),
      ];
      if (constraints.maxWidth < 700) {
        return Column(
          children: <Widget>[
            for (var index = 0; index < cards.length; index++) ...<Widget>[
              if (index > 0) const SizedBox(height: AppSpacing.regular),
              cards[index],
            ],
          ],
        );
      }
      final width = (constraints.maxWidth - AppSpacing.regular * (cards.length - 1)) / cards.length;
      return Wrap(
        spacing: AppSpacing.regular,
        runSpacing: AppSpacing.regular,
        children: <Widget>[for (final card in cards) SizedBox(width: width, child: card)],
      );
    },
  );
}

class AppTransferPanel extends StatelessWidget {
  const AppTransferPanel({
    required this.state,
    required this.onScanQr,
    required this.onInstall,
    required this.onCancel,
    required this.onReset,
    this.showActions = true,
    super.key,
  });

  final AppTransferState state;
  final VoidCallback? onScanQr;
  final ValueChanged<bool> onInstall;
  final VoidCallback onCancel;
  final VoidCallback onReset;
  final bool showActions;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('app-transfer-panel'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      _AppStatusCard(state: state),
      const SizedBox(height: AppSpacing.regular),
      if (state.phase == AppTransferPhase.waitingForPeer && state.connectionOffer != null)
        _AppQrCard(offer: state.connectionOffer!, version: state.localVersion)
      else if (state.phase == AppTransferPhase.awaitingQr) ...<Widget>[
        const _AppHint('请扫描发送 App 设备显示的二维码，局域网内不会自动发现或广播设备。'),
        if (onScanQr != null) ...<Widget>[
          const SizedBox(height: AppSpacing.compact),
          FilledButton.icon(
            key: const Key('app-transfer-scan-qr'),
            onPressed: onScanQr,
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('扫描二维码'),
          ),
        ],
      ] else if (state.phase == AppTransferPhase.pairing || state.phase == AppTransferPhase.ready) ...<Widget>[
        AppVersionComparisonCard(
          local: state.role == AppTransferRole.sender ? state.offeredVersion : state.localVersion,
          remote: state.role == AppTransferRole.sender ? state.remoteVersion : state.offeredVersion,
          pairingCode: state.pairingCode,
          localLabel: state.role == AppTransferRole.sender ? '将发送' : '本机',
          remoteLabel: state.role == AppTransferRole.sender ? '对方' : '对方提供',
        ),
        if (state.phase == AppTransferPhase.ready) ...<Widget>[
          const SizedBox(height: AppSpacing.regular),
          FilledButton.icon(
            key: Key(state.remoteIsUpgrade ? 'app-transfer-upgrade' : 'app-transfer-force'),
            onPressed: () => onInstall(!state.remoteIsUpgrade),
            icon: Icon(state.remoteIsUpgrade ? Icons.system_update_alt_rounded : Icons.replay_rounded),
            label: Text(state.remoteIsUpgrade ? '确认升级' : '强制安装此版本'),
          ),
        ],
      ] else if (state.phase == AppTransferPhase.downloading || state.phase == AppTransferPhase.launchingInstaller) ...<Widget>[
        LinearProgressIndicator(value: state.progress, key: const Key('app-transfer-progress')),
      ],
      if (showActions) ...<Widget>[
        const SizedBox(height: AppSpacing.regular),
        if (state.phase == AppTransferPhase.completed || state.phase == AppTransferPhase.failed)
          FilledButton(key: const Key('app-transfer-finish'), onPressed: onReset, child: const Text('完成'))
        else
          OutlinedButton(key: const Key('app-transfer-cancel'), onPressed: onCancel, child: const Text('取消 App 传输')),
      ],
    ],
  );
}

class AppVersionComparisonCard extends StatelessWidget {
  const AppVersionComparisonCard({
    required this.local,
    required this.remote,
    required this.pairingCode,
    this.localLabel = '本机',
    this.remoteLabel = '对方提供',
    super.key,
  });

  final AppVersionInfo? local;
  final AppVersionInfo? remote;
  final String? pairingCode;
  final String localLabel;
  final String remoteLabel;

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('app-transfer-version-comparison'),
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.regular),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('核对 App 版本', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.compact),
          _VersionRow(label: localLabel, value: local),
          const SizedBox(height: AppSpacing.unit),
          _VersionRow(label: remoteLabel, value: remote),
          if (pairingCode != null) ...<Widget>[
            const Divider(height: AppSpacing.section),
            const Text('两台设备应显示相同确认码', textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.compact),
            SelectableText(
              pairingCode!,
              key: const Key('app-transfer-pairing-code'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 5),
            ),
          ],
        ],
      ),
    ),
  );
}

class _VersionRow extends StatelessWidget {
  const _VersionRow({required this.label, required this.value});
  final String label;
  final AppVersionInfo? value;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      SizedBox(width: 84, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
      Expanded(child: Text(value?.displayVersion ?? '--', style: Theme.of(context).textTheme.titleSmall)),
      Text(value?.platform.name.toUpperCase() ?? '', style: Theme.of(context).textTheme.labelSmall),
    ],
  );
}

class _AppStatusCard extends StatelessWidget {
  const _AppStatusCard({required this.state});
  final AppTransferState state;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: state.active
          ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(state.phase == AppTransferPhase.failed ? Icons.error_outline_rounded : Icons.mobile_friendly_rounded),
      title: Text(state.message),
      subtitle: state.errorCode == null ? null : Text('错误码：${state.errorCode}'),
    ),
  );
}

class _AppQrCard extends StatelessWidget {
  const _AppQrCard({required this.offer, required this.version});
  final AppTransferConnectionOffer offer;
  final AppVersionInfo? version;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.regular),
      child: Column(
        children: <Widget>[
          Text('发送 App ${version?.displayVersion ?? ''}', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.regular),
          ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.compact),
              child: QrImageView(
                key: const Key('app-transfer-sender-qr'),
                data: AppTransferQrPayload.encode(offer),
                size: 220,
                backgroundColor: Theme.of(context).colorScheme.surface,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.compact),
          const Text('对方扫码后会先看到双方版本，并自行确认是否升级。'),
        ],
      ),
    ),
  );
}

class _AppHint extends StatelessWidget {
  const _AppHint(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(leading: const Icon(Icons.info_outline_rounded), title: Text(message)),
  );
}

class _AppRoleCard extends StatelessWidget {
  const _AppRoleCard({required this.icon, required this.title, required this.description, required this.onTap, super.key});
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    color: const Color(0xFFFFF7EE),
    child: InkWell(
      borderRadius: AppRadii.detailControl,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: Row(
          children: <Widget>[
            Icon(icon, color: AppThemeTokens.of(context).dataSourceAccent, size: 30),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: AppSpacing.unit),
                  Text(description, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
