/// Direct LAN TV selection, playback control, and TV-side reception status.
///
/// Leaving this page stops only its discovery subscription and control lease;
/// it never stops playback on either device. Presentation widgets receive
/// projections and callbacks; only this route coordinates discovery and IO.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';

import '../application/companion_controller.dart';
import '../domain/companion_models.dart';
import 'companion_catalog_page.dart';
import 'companion_discovery_startup.dart';
import 'companion_devices_view.dart';
import 'companion_history_page.dart';
import 'companion_messages.dart';
import 'companion_remote.dart';
import 'companion_receiver_view.dart';
import 'companion_widgets.dart';
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
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('局域网 TV 播放', maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(
                tv ? '电视接收端' : '手机连接电视，选片与遥控',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
          actions: tv ? [IconButton(tooltip: '刷新状态', onPressed: _busy ? null : _start, icon: const Icon(Icons.refresh_rounded))] : null,
        ),
        body: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: Column(
                children: [
                  SizedBox(height: 3, child: _busy ? const LinearProgressIndicator() : null),
                  if (!tv)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.compactPagePadding,
                        AppSpacing.compact,
                        AppSpacing.compactPagePadding,
                        0,
                      ),
                      child: CompanionPageTabs(selected: _tab, onChanged: (value) => setState(() => _tab = value)),
                    ),
                  Expanded(
                    child: tv
                        ? _receiverStatus()
                        : _tab != 0 && service.connectionStatus != CompanionConnectionStatus.connected
                        ? CompanionConnectionRequired(
                            catalog: _tab == 2,
                            reconnecting:
                                service.connectionStatus == CompanionConnectionStatus.reconnecting ||
                                service.connectionStatus == CompanionConnectionStatus.connecting,
                            onDevices: () => setState(() => _tab = 0),
                          )
                        : _tab == 1
                        ? CompanionRemote(service: service)
                        : _tab == 2
                        ? CompanionCatalogPage(key: ValueKey(service.selectedDeviceId), service: service, embedded: true)
                        : _devicePicker(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tools() => CompanionTools(
    onHistory: () => Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => const CompanionHistoryPage())),
    onSync: _busy ? null : () => _run(() => ref.read(companionOpenDeviceSyncProvider)()),
  );

  Widget _receiverStatus() => CompanionReceiverView(
    enabled: service.receiverEnabled,
    error: _notice,
    label: service.identity?.label ?? '本机 TV',
    addresses: [
      if (service.hostPort != null)
        for (final address in service.localAddresses) '$address:${service.hostPort}',
    ],
    controllers: service.connectedControllerIds.map(service.deviceLabel).toList(),
    tools: _tools(),
  );

  Widget _devicePicker() {
    final endpoints =
        service.endpoints.values.where((endpoint) => endpoint.receiving && endpoint.expiresAt.isAfter(DateTime.now())).toList()
          ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return CompanionDevicesView(
      endpoints: endpoints,
      status: service.connectionStatus,
      selectedId: service.selectedDeviceId,
      selectedLabel: service.selectedLabel,
      stale: service.stale,
      playingTitle: service.remoteState?.content?.title,
      busy: _busy,
      discovering: _discoveryStarted && _notice == null,
      error: _notice ?? (service.errorCode == null ? null : companionErrorText(service.errorCode)),
      onRefresh: _start,
      onManual: _manual,
      onDisconnect: () => _run(service.disconnect),
      onRemote: () => setState(() => _tab = 1),
      onCatalog: () => setState(() => _tab = 2),
      onConnect: (endpoint) => _run(() async {
        await service.connect(endpoint);
        if (mounted) setState(() => _tab = 1);
      }),
      tools: _tools(),
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
