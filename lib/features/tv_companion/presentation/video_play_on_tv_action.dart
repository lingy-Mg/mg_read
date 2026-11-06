/// Player-owned entry point for direct LAN playback on a nearby TV.
///
/// This UI only discovers and selects a receiver. Playback remains owned by
/// the existing companion handoff and media host contracts.
/// Discovery is scoped to the picker; the entry shares the player's toolbar.
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
import 'video_tv_picker_sheet.dart';

/// Compact host action rendered inside the reusable player's top toolbar.
final class VideoPlayOnTvAction extends ConsumerWidget {
  const VideoPlayOnTvAction({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    key: const Key('video-play-on-tv'),
    onPressed: () => unawaited(_chooseAndPlay(context, ref)),
    tooltip: '在电视上播放',
    icon: const Icon(Icons.cast_rounded, size: 21),
    style: IconButton.styleFrom(foregroundColor: Colors.white, visualDensity: VisualDensity.compact),
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
    useSafeArea: true,
    showDragHandle: false,
    backgroundColor: VideoTvPickerSheet.backgroundColor,
    barrierColor: Colors.black54,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    clipBehavior: Clip.antiAlias,
    constraints: const BoxConstraints(maxWidth: 560),
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
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.service,
    builder: (context, _) {
      final endpoints =
          widget.service.endpoints.values.where((endpoint) => endpoint.receiving && endpoint.expiresAt.isAfter(DateTime.now())).toList()
            ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      return VideoTvPickerSheet(
        loading: _loading,
        error: _error,
        endpoints: endpoints,
        onSelect: (endpoint) => Navigator.of(context).pop(_TvTarget.endpoint(endpoint)),
        onManual: _manual,
        onRetry: _retry,
        onClose: () => Navigator.of(context).pop(),
      );
    },
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
