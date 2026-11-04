/// Player-owned entry point for direct LAN playback on a nearby TV.
///
/// This UI only discovers and selects a receiver. Playback remains owned by
/// the existing companion handoff and media host contracts.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';

import '../application/companion_controller.dart';
import '../application/companion_media_host.dart';
import '../domain/companion_command.dart';
import '../domain/companion_models.dart';
import 'companion_discovery_startup.dart';
import 'manual_tv_address_dialog.dart';
import 'companion_messages.dart';

/// Host-provided action rendered in the reusable player's upper-right corner.
final class VideoPlayOnTvAction extends ConsumerWidget {
  const VideoPlayOnTvAction({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => FilledButton.tonalIcon(
    key: const Key('video-play-on-tv'),
    onPressed: () => unawaited(_chooseAndPlay(context, ref)),
    icon: const Icon(Icons.connected_tv),
    label: const Text('在电视上播放'),
    style: FilledButton.styleFrom(backgroundColor: const Color(0xD9161A1F), foregroundColor: Colors.white),
  );
}

Future<void> _chooseAndPlay(BuildContext context, WidgetRef ref) async {
  final media = ref.read(companionMediaHostProvider);
  final content = media.content;
  if (content == null) return;
  final service = ref.read(companionControllerProvider);
  final target = await showModalBottomSheet<_TvTarget>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _TvPickerSheet(key: const Key('companion-cast-picker'), service: service),
  );
  if (target == null || !context.mounted) return;
  final current = media.content;
  if (current == null ||
      current.identity != content.identity ||
      current.groupId != content.groupId ||
      current.episodeId != content.episodeId) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('当前视频已切换，请重新选择 TV。')));
    return;
  }
  try {
    if (target.endpoint case final endpoint?) {
      if (service.connectionStatus != CompanionConnectionStatus.connected || service.selectedDeviceId != endpoint.deviceId) {
        await service.connect(endpoint);
      }
    } else {
      await service.connectManual(address: target.address!, port: target.port!);
    }
    final latest = media.content;
    if (latest == null ||
        latest.identity != content.identity ||
        latest.groupId != content.groupId ||
        latest.episodeId != content.episodeId) {
      throw const CompanionFailure('media_selection_changed');
    }
    final result = await service.handoff(
      companionHandoffContentForTarget(phoneContent: latest, tvContent: service.remoteState?.content, tvStateFresh: !service.stale),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.phase == CompanionCommandPhase.started ? '已在 ${service.selectedLabel} 开始播放' : companionErrorText(result.code)),
      ),
    );
  } on Object catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'))));
  }
}

CompanionContentRef companionHandoffContentForTarget({
  required CompanionContentRef phoneContent,
  required CompanionContentRef? tvContent,
  required bool tvStateFresh,
}) {
  if (!tvStateFresh ||
      tvContent?.identity != phoneContent.identity ||
      tvContent?.groupId != phoneContent.groupId ||
      tvContent?.episodeId != phoneContent.episodeId) {
    return phoneContent;
  }
  return CompanionContentRef(
    pluginId: phoneContent.pluginId,
    pluginVersion: phoneContent.pluginVersion,
    contentId: phoneContent.contentId,
    title: phoneContent.title,
    groupId: phoneContent.groupId,
    episodeId: phoneContent.episodeId,
    positionMs: phoneContent.positionMs,
    useTvProgress: true,
  );
}

final class _TvTarget {
  const _TvTarget.endpoint(this.endpoint) : address = null, port = null;
  const _TvTarget.manual(this.address, this.port) : endpoint = null;
  final CompanionEndpoint? endpoint;
  final String? address;
  final int? port;
}

final class _TvPickerSheet extends ConsumerStatefulWidget {
  const _TvPickerSheet({super.key, required this.service});
  final CompanionController service;

  @override
  ConsumerState<_TvPickerSheet> createState() => _TvPickerSheetState();
}

final class _TvPickerSheetState extends ConsumerState<_TvPickerSheet> {
  late final DeviceSyncController _sync;
  bool _loading = true;
  bool _discoveryStarted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sync = ref.read(deviceSyncControllerProvider.notifier);
    unawaited(_startDiscovery());
  }

  Future<void> _startDiscovery() async {
    try {
      if (!_discoveryStarted) {
        _discoveryStarted = await startCompanionDiscovery(
          discover: () => widget.service.discover(true),
          ensurePeerServices: _sync.ensurePeerServices,
          isMounted: () => mounted,
          stopDiscovery: () async {
            await widget.service.discover(false);
            await _sync.reloadDevices();
          },
          onDiscoveryStarted: () => _discoveryStarted = true,
        );
        if (!mounted || !_discoveryStarted) return;
      } else {
        await _sync.ensurePeerServices();
      }
      if (mounted) setState(() => _loading = false);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = companionErrorText(error is CompanionFailure ? error.code : 'operation_failed');
        });
      }
    }
  }

  @override
  void dispose() {
    if (_discoveryStarted) {
      unawaited(widget.service.discover(false).then((_) => _sync.reloadDevices()).catchError((Object _) {}));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: AnimatedBuilder(
      animation: widget.service,
      builder: (context, _) {
        final endpoints =
            widget.service.endpoints.values.where((endpoint) => endpoint.receiving && endpoint.expiresAt.isAfter(DateTime.now())).toList()
              ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .78),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            children: [
              Text('选择局域网 TV', style: Theme.of(context).textTheme.titleLarge),
              const Padding(padding: EdgeInsets.only(top: 6, bottom: 12), child: Text('直接在所选设备播放。手机会在 TV 实际起播后暂停。')),
              if (_loading)
                const ListTile(
                  leading: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)),
                  title: Text('正在搜索 TV…'),
                ),
              if (_error case final error?) ListTile(leading: const Icon(Icons.wifi_off), title: Text(error)),
              if (!_loading && endpoints.isEmpty) const ListTile(leading: Icon(Icons.tv_off), title: Text('暂未发现 TV，请确认两台设备在可互访的局域网。')),
              for (final endpoint in endpoints)
                ListTile(
                  key: Key('companion-cast-device-${endpoint.deviceId}'),
                  leading: const Icon(Icons.tv),
                  title: Text(endpoint.label),
                  subtitle: Text('${endpoint.address}:${endpoint.port}'),
                  trailing: const Icon(Icons.play_arrow),
                  onTap: () => Navigator.of(context).pop(_TvTarget.endpoint(endpoint)),
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.edit_road),
                title: const Text('手动输入 TV 地址'),
                subtitle: const Text('仅填写局域网 IP 地址和端口'),
                onTap: _manual,
              ),
              if (!_loading && (endpoints.isEmpty || _error != null))
                TextButton.icon(onPressed: _retry, icon: const Icon(Icons.refresh), label: const Text('重新搜索')),
            ],
          ),
        );
      },
    ),
  );

  Future<void> _retry() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _startDiscovery();
  }

  Future<void> _manual() async {
    final target = await showManualTvAddressDialog(context);
    if (target != null && mounted) Navigator.of(context).pop(_TvTarget.manual(target.address, target.port));
  }
}
