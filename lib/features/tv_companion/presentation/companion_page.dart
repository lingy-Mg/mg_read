/// Device management and pairing. Leaving this page cancels only a pending
/// pairing/discovery subscription, never the receiver or a TV playback session.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';
import 'package:mg_read/features/lan_sync/domain/lan_pairing_payload.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';
import 'package:mg_read/features/lan_sync/presentation/lan_sync_qr_code.dart';
import 'package:mg_read/features/lan_sync/presentation/lan_sync_qr_scanner_page.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import '../application/companion_controller.dart';
import '../data/companion_repository.dart';
import '../domain/companion_models.dart';
import 'companion_remote.dart';
import 'companion_catalog_page.dart';
import 'companion_messages.dart';
import 'companion_history_page.dart';

Future<void> openCompanionPage(BuildContext context) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => const CompanionPage(),
    settings: const RouteSettings(name: 'tv-companion'),
  ),
);

class CompanionPage extends ConsumerStatefulWidget {
  const CompanionPage({super.key});
  @override
  ConsumerState<CompanionPage> createState() => _CompanionPageState();
}

class _CompanionPageState extends ConsumerState<CompanionPage> {
  late final CompanionController service;
  late final DeviceSyncController _sync;
  late final CompanionNavigationGuard _guard;
  ModalRoute<dynamic>? _route;
  bool _busy = false, _browse = false, _discoveryStarted = false;
  int _tab = 0;
  String? _notice;
  @override
  void initState() {
    super.initState();
    service = ref.read(companionControllerProvider);
    _sync = ref.read(deviceSyncControllerProvider.notifier);
    _guard = ref.read(companionNavigationGuardProvider)..enter(this, isCurrent: () => mounted && (_route?.isCurrent ?? true));
    unawaited(_start());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  Future<void> _start() async {
    await _run(() async {
      if (!_discoveryStarted) {
        await service.discover(true);
        if (!mounted) {
          await service.discover(false);
          return;
        }
        _discoveryStarted = true;
      }
      await _sync.ensurePeerServices();
      await service.refreshPolicies();
    });
  }

  @override
  void dispose() {
    if (_discoveryStarted) unawaited(service.discover(false).then((_) => _sync.reloadDevices()).catchError((Object _) {}));
    unawaited(service.releaseControl());
    _guard.leave(this);
    // Pairing UI must remain present for the local confirmation.
    unawaited(_sync.cancelPairing());
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) setState(() => _notice = companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await service.refreshPolicies();
  }

  @override
  Widget build(BuildContext context) {
    final pairing = ref.watch(deviceSyncControllerProvider);
    final tv = TvModeScope.isEnabled(context);
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('手机辅助 TV'),
          actions: [IconButton(tooltip: '重新发现', onPressed: _busy ? null : _start, icon: const Icon(Icons.refresh))],
        ),
        body: Column(
          children: [
            if (_notice != null)
              MaterialBanner(
                content: Text(_notice!),
                actions: [TextButton(onPressed: () => setState(() => _notice = null), child: const Text('知道了'))],
              ),
            if (_busy) const LinearProgressIndicator(),
            if (!tv)
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('设备')),
                  ButtonSegment(value: 1, label: Text('遥控')),
                  ButtonSegment(value: 2, label: Text('TV 找片')),
                ],
                selected: {_tab},
                onSelectionChanged: (value) => setState(() => _tab = value.single),
              ),
            Expanded(
              child: !tv && _tab == 1
                  ? CompanionRemote(service: service)
                  : !tv && _tab == 2
                  ? CompanionCatalogPage(service: service, embedded: true)
                  : ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        Text('手机找片，TV 自行播放', style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 8),
                        const Text('请让两端 MgRead 连接可互访的同一局域网。关闭遥控页或手机锁屏不会停止 TV 播放。'),
                        const SizedBox(height: 16),
                        SwitchListTile(
                          title: const Text('允许本机接收手机控制'),
                          subtitle: Text(service.receiverEnabled ? '应用前台时可接收已授权手机' : '默认关闭，需要本机明确开启'),
                          value: service.receiverEnabled,
                          onChanged: _busy
                              ? null
                              : (value) => _run(() async {
                                  await service.setReceiverEnabled(value);
                                  await _sync.ensurePeerServices();
                                }),
                        ),
                        if (service.receiverEnabled) ...[
                          Text('本机：${service.identity?.label ?? '正在读取'} · ${_short(service.identity?.deviceId ?? '')}'),
                          if (service.hostPort != null)
                            for (final address in service.localAddresses) SelectableText('$address:${service.hostPort}'),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _run(() async {
                                    await _sync.beginPairing(companionOnly: true);
                                  }),
                            icon: const Icon(Icons.qr_code),
                            label: const Text('配对新手机'),
                          ),
                        ],
                        if (!tv)
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _busy ? null : _scan,
                                icon: const Icon(Icons.qr_code_scanner),
                                label: const Text('扫描 TV 二维码'),
                              ),
                              OutlinedButton(onPressed: _busy ? null : () => _manual(pairing.devices), child: const Text('手动连接')),
                            ],
                          ),
                        ..._pairing(pairing),
                        const SizedBox(height: 24),
                        Text('发现的 TV', style: Theme.of(context).textTheme.titleLarge),
                        if (service.endpoints.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Text('暂未发现接收端。请在 TV 开启接收；也可扫码或手动连接。访客 Wi-Fi 和客户端隔离可能阻止互访。'),
                          ),
                        for (final endpoint in service.endpoints.values)
                          Card(
                            child: ListTile(
                              leading: Icon(endpoint.receiving ? Icons.tv : Icons.tv_off),
                              title: Text(endpoint.label),
                              subtitle: Text('${_short(endpoint.deviceId)} · ${endpoint.receiving ? '可接收' : '未开启接收'}'),
                              trailing: TextButton(
                                onPressed: !endpoint.receiving || _busy
                                    ? null
                                    : () => _run(() async {
                                        await service.connect(endpoint);
                                        if (mounted) setState(() => _tab = 1);
                                      }),
                                child: const Text('连接'),
                              ),
                            ),
                          ),
                        const SizedBox(height: 24),
                        Text('已配对设备与授权', style: Theme.of(context).textTheme.titleLarge),
                        for (final device in pairing.devices) _device(device),
                        for (final id in service.pendingControlRequests)
                          Card(
                            child: ListTile(
                              title: Text('${_label(id, pairing.devices)} 请求接管控制'),
                              trailing: TextButton(
                                onPressed: () => setState(() {
                                  service.grantControl(id);
                                  service.pendingControlRequests.remove(id);
                                }),
                                child: const Text('允许接管'),
                              ),
                            ),
                          ),
                        if (service.connectedControllerIds.isNotEmpty)
                          Text('已连接手机：${service.connectedControllerIds.map((id) => _label(id, pairing.devices)).join('、')}'),
                        if (service.errorCode != null) Text(companionErrorText(service.errorCode)),
                      ],
                    ),
            ),
            Wrap(
              spacing: 12,
              children: [
                TextButton.icon(
                  onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const CompanionHistoryPage())),
                  icon: const Icon(Icons.history),
                  label: const Text('本机与 TV 观看记录'),
                ),
                TextButton.icon(
                  onPressed: () => _run(() => ref.read(companionOpenDeviceSyncProvider)()),
                  icon: const Icon(Icons.sync),
                  label: const Text('设备同步 / 来源传输'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _pairing(DeviceSyncState state) {
    final offer = state.pairingOffer;
    final code = state.pairingCode;
    return [
      if (offer != null)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('二维码十分钟内有效，请勿分享给其他人。'),
                SizedBox(
                  width: 244,
                  child: LanSyncQrCode(
                    data: LanPairingQrPayload.encode(offer),
                    semanticsLabel: '手机辅助 TV 配对二维码',
                    qrKey: const Key('companion-pair-qr'),
                  ),
                ),
                if (state.manualPairingCode != null) ...[
                  const Text('无法扫码时，在手机输入地址和连接密钥：'),
                  for (final address in offer.addresses) SelectableText('$address:${offer.port}'),
                  SelectableText(state.manualPairingCode!, style: Theme.of(context).textTheme.titleLarge),
                ],
                TextButton(onPressed: () => _sync.cancelPairing(), child: const Text('取消配对')),
              ],
            ),
          ),
        ),
      if (code != null)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('请核对双方设备：${state.pairingPeer?.label ?? ''}'),
                Text(code, style: Theme.of(context).textTheme.headlineLarge),
                const Text('仅在两端六位确认码一致时继续。'),
                if (state.pairingPhase == DevicePairingPhase.confirming) ...[
                  CheckboxListTile(
                    value: _browse,
                    onChanged: (value) => setState(() => _browse = value ?? false),
                    title: const Text('同时允许查看本机普通收藏与观看记录'),
                  ),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            final peer = state.pairingPeer!;
                            await _sync.approvePairing();
                            await service.setPolicy(peer.deviceId, CompanionPolicy(control: true, browseLibrary: _browse));
                          }),
                    child: const Text('一致，允许遥控'),
                  ),
                  TextButton(onPressed: () => _sync.rejectPairing(), child: const Text('不一致，拒绝')),
                ] else if (state.pairingPhase == DevicePairingPhase.waitingApproval)
                  FilledButton(onPressed: () => _sync.confirmPairingCode(), child: const Text('两端一致，继续')),
              ],
            ),
          ),
        ),
      if (state.pairingPhase == DevicePairingPhase.completed) const Padding(padding: EdgeInsets.all(12), child: Text('配对已保存。请选择目标 TV 连接。')),
      if (state.pairingPhase == DevicePairingPhase.failed) Text(state.lastMessage ?? '配对未完成，请重试。'),
    ];
  }

  Widget _device(PairedDevice device) {
    final policy = service.policies[device.deviceId] ?? const CompanionPolicy();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${policy.label ?? device.label} · ${_short(device.deviceId)}', style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              title: const Text('允许此设备控制本机'),
              value: policy.control,
              onChanged: _busy
                  ? null
                  : (value) => _run(
                      () => service.setPolicy(
                        device.deviceId,
                        CompanionPolicy(control: value, browseLibrary: value && policy.browseLibrary, label: policy.label),
                      ),
                    ),
            ),
            if (policy.control)
              SwitchListTile(
                title: const Text('允许查看普通收藏与观看记录'),
                value: policy.browseLibrary,
                onChanged: _busy
                    ? null
                    : (value) => _run(
                        () => service.setPolicy(device.deviceId, CompanionPolicy(control: true, browseLibrary: value, label: policy.label)),
                      ),
              ),
            Wrap(
              spacing: 12,
              children: [
                TextButton(onPressed: () => _rename(device, policy), child: const Text('备注名称')),
                TextButton(
                  onPressed: () => _run(() async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('解除配对？'),
                        content: Text('将撤销 ${device.label} 的全部信任。它正在播放的内容会继续。'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('解除配对')),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await service.setPolicy(device.deviceId, const CompanionPolicy());
                      await _sync.removeDevice(device.deviceId);
                    }
                  }),
                  child: const Text('解除配对'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(PairedDevice device, CompanionPolicy policy) async {
    final editor = TextEditingController(text: policy.label ?? device.label);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设备备注'),
        content: TextField(controller: editor, maxLength: 64),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, editor.text.trim()), child: const Text('保存')),
        ],
      ),
    );
    editor.dispose();
    if (name != null && name.isNotEmpty) {
      await _run(
        () =>
            service.setPolicy(device.deviceId, CompanionPolicy(control: policy.control, browseLibrary: policy.browseLibrary, label: name)),
      );
    }
  }

  Future<void> _scan() async {
    final payload = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const LanSyncQrScannerPage(purpose: LanSyncQrScannerPurpose.pairing)));
    if (payload != null && mounted) {
      unawaited(_sync.joinPairing(payload));
    }
  }

  Future<void> _manual(List<PairedDevice> devices) async {
    final address = TextEditingController(), port = TextEditingController(), code = TextEditingController();
    String? selected = devices.firstOrNull?.deviceId;
    final connect = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          scrollable: true,
          title: const Text('手动连接 TV'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('地址和端口请以 TV 当前显示为准。首次连接需输入 TV 配对页的完整连接密钥。'),
                TextField(
                  controller: address,
                  decoration: const InputDecoration(labelText: 'TV 私网 IPv4 地址'),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: port,
                  decoration: const InputDecoration(labelText: '端口'),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: code,
                  decoration: const InputDecoration(labelText: '首次配对连接密钥；已配对可留空'),
                ),
                if (devices.isNotEmpty)
                  DropdownButtonFormField<String>(
                    initialValue: selected,
                    items: [
                      for (final device in devices)
                        DropdownMenuItem(value: device.deviceId, child: Text('${device.label} · ${_short(device.deviceId)}')),
                    ],
                    onChanged: (value) => setLocal(() => selected = value),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('连接')),
          ],
        ),
      ),
    );
    final host = address.text.trim(), number = int.tryParse(port.text.trim()), secret = code.text.trim();
    address.dispose();
    port.dispose();
    code.dispose();
    if (connect != true) return;
    await _run(() async {
      if (number == null) throw const CompanionFailure('invalid_lan_endpoint');
      if (secret.isNotEmpty) {
        unawaited(_sync.joinManualPairing(address: host, port: number, code: secret));
      } else {
        if (selected == null) throw const CompanionFailure('not_paired');
        await service.connectManual(address: host, port: number, deviceId: selected!);
        if (mounted) setState(() => _tab = 1);
      }
    });
  }

  String _short(String id) => id.length > 6 ? id.substring(id.length - 6) : id;
  String _label(String id, List<PairedDevice> devices) => devices.where((device) => device.deviceId == id).firstOrNull?.label ?? _short(id);
}
