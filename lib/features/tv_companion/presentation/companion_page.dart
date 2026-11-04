/// Direct LAN TV selection, playback control, and TV-side reception status.
///
/// Leaving this page stops only its discovery subscription and control lease;
/// it never stops playback on either device.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';

import '../application/companion_controller.dart';
import '../domain/companion_models.dart';
import 'companion_catalog_page.dart';
import 'companion_discovery_startup.dart';
import 'companion_history_page.dart';
import 'companion_messages.dart';
import 'companion_remote.dart';
import 'manual_tv_address_dialog.dart';

Future<void> openCompanionPage(BuildContext context) => Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    builder: (_) => const CompanionPage(),
    settings: const RouteSettings(name: 'tv-companion'),
  ),
);

final class CompanionPage extends ConsumerStatefulWidget {
  const CompanionPage({super.key});

  @override
  ConsumerState<CompanionPage> createState() => _CompanionPageState();
}

final class _CompanionPageState extends ConsumerState<CompanionPage> {
  late final CompanionController service;
  late final DeviceSyncController _sync;
  late final CompanionNavigationGuard _guard;
  ModalRoute<dynamic>? _route;
  bool _busy = false, _discoveryStarted = false;
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
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      if (!_discoveryStarted) {
        _discoveryStarted = await startCompanionDiscovery(
          discover: () => service.discover(true),
          ensurePeerServices: _sync.ensurePeerServices,
          isMounted: () => mounted,
          stopDiscovery: () async {
            await service.discover(false);
            await _sync.reloadDevices();
          },
          onDiscoveryStarted: () => _discoveryStarted = true,
        );
        if (!mounted || !_discoveryStarted) return;
      } else {
        await _sync.ensurePeerServices();
      }
    } on Object catch (error) {
      if (mounted) setState(() => _notice = companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    if (_discoveryStarted) unawaited(service.discover(false).then((_) => _sync.reloadDevices()).catchError((Object _) {}));
    unawaited(service.releaseControl());
    _guard.leave(this);
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
  }

  @override
  Widget build(BuildContext context) {
    final tv = TvModeScope.isEnabled(context);
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('局域网 TV 播放'),
          actions: [IconButton(tooltip: '重新搜索', onPressed: _busy ? null : _start, icon: const Icon(Icons.refresh))],
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
              child: tv
                  ? _receiverStatus()
                  : _tab == 1
                  ? CompanionRemote(service: service)
                  : _tab == 2
                  ? CompanionCatalogPage(service: service, embedded: true)
                  : _devicePicker(),
            ),
            Wrap(
              spacing: 12,
              children: [
                TextButton.icon(
                  onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => const CompanionHistoryPage())),
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

  Widget _receiverStatus() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text('TV 接收状态', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      Text(service.receiverEnabled ? '本机正在同一局域网开放视频接收。' : '本机当前未开放 TV 接收。'),
      if (service.identity != null) ...[const SizedBox(height: 12), Text('设备：${service.identity!.label}')],
      if (service.hostPort != null) ...[
        const SizedBox(height: 8),
        for (final address in service.localAddresses) SelectableText('$address:${service.hostPort}'),
      ],
      const SizedBox(height: 16),
      const Text('手机可在播放器右上角选择本机播放。来源页面与手机播放记录按各自设备管理。'),
      if (service.connectedControllerIds.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text('当前手机连接：${service.connectedControllerIds.map(service.deviceLabel).join('、')}'),
      ],
    ],
  );

  Widget _devicePicker() {
    final endpoints =
        service.endpoints.values.where((endpoint) => endpoint.receiving && endpoint.expiresAt.isAfter(DateTime.now())).toList()
          ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('发现 TV', style: Theme.of(context).textTheme.titleLarge),
        const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('手机与 TV 需要在可互访的同一局域网。直接连接并在 TV 播放，不需要扫码配对或电视端批准。')),
        if (service.connectionStatus == CompanionConnectionStatus.connected)
          Card(
            child: ListTile(
              leading: const Icon(Icons.connected_tv),
              title: Text('${service.selectedLabel} · ${service.stale ? '状态延迟' : '已连接'}'),
              trailing: TextButton(onPressed: _busy ? null : () => _run(service.disconnect), child: const Text('断开')),
              subtitle: const Text('断开遥控连接不会停止 TV 播放'),
            ),
          ),
        if (endpoints.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('暂未发现 TV。请打开 TV 上的 MgRead 并检查访客 Wi-Fi 或设备隔离设置。')),
        for (final endpoint in endpoints)
          Card(
            child: ListTile(
              leading: const Icon(Icons.tv),
              title: Text(endpoint.label),
              subtitle: Text('${endpoint.address}:${endpoint.port} · 可接收'),
              trailing: FilledButton.tonal(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await service.connect(endpoint);
                        if (mounted) setState(() => _tab = 1);
                      }),
                child: Text(
                  service.selectedDeviceId == endpoint.deviceId && service.connectionStatus == CompanionConnectionStatus.connected
                      ? '已连接'
                      : '连接',
                ),
              ),
            ),
          ),
        OutlinedButton.icon(onPressed: _busy ? null : _manual, icon: const Icon(Icons.edit_road), label: const Text('手动输入 TV 地址')),
        if (service.errorCode != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(companionErrorText(service.errorCode))),
      ],
    );
  }

  Future<void> _manual() async {
    final target = await showManualTvAddressDialog(context);
    if (target == null) return;
    await _run(() async {
      await service.connectManual(address: target.address, port: target.port);
      if (mounted) setState(() => _tab = 1);
    });
  }
}
