/// Local video history remains available when the TV is offline. Concurrent
/// device branches are shown explicitly instead of silently picking a winner.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import '../application/companion_controller.dart';
import '../domain/companion_models.dart';
import '../domain/companion_command.dart';
import 'companion_messages.dart';

class CompanionHistoryPage extends ConsumerStatefulWidget {
  const CompanionHistoryPage({super.key});
  @override
  ConsumerState<CompanionHistoryPage> createState() => _CompanionHistoryPageState();
}

class _CompanionHistoryPageState extends ConsumerState<CompanionHistoryPage> {
  List<VideoHistoryCheckpoint> _entries = [];
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final getter = ref.read(companionLibraryProvider);
      if (getter == null) throw const CompanionFailure('library_unavailable');
      final entries = await (await getter()).listVideoHistory(limit: 500, includeRemoteBranches: true);
      final distinct = <String, VideoHistoryCheckpoint>{};
      for (final entry in entries) {
        final item = entry.checkpoint;
        distinct.putIfAbsent(jsonEncode([item.sourceKey, item.originDeviceId, item.playbackSessionId, item.sequence]), () => item);
      }
      if (mounted) setState(() => _entries = distinct.values.toList(growable: false));
    } on Object {
      if (mounted) setState(() => _error = '观看记录暂时无法读取，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.read(companionControllerProvider);
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('本机与 TV 观看记录'),
          actions: [IconButton(tooltip: '刷新观看记录', onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh))],
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('已同步的记录可在 TV 离线时使用。存在不同设备的记录时，请明确选择；在手机播放不会自动停止 TV。'),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null) Text(_error!),
            if (_entries.isEmpty && !_busy) const Padding(padding: EdgeInsets.all(24), child: Text('暂无观看记录。视频起播后的进度会保存在这里，无需先收藏。')),
            for (final entry in _entries)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.title, style: Theme.of(context).textTheme.titleLarge),
                      Text(
                        '${entry.originDeviceId == service.identity?.deviceId ? '本机' : service.deviceLabel(entry.originDeviceId)} · ${_time(entry.position)} / ${_time(entry.duration)}',
                      ),
                      Text(entry.updatedAtUtc.toLocal().toString().substring(0, 19)),
                      Wrap(
                        spacing: 12,
                        children: [
                          TextButton.icon(
                            onPressed: _busy ? null : () => _play(entry, false),
                            icon: const Icon(Icons.phone_android),
                            label: const Text('在本机继续'),
                          ),
                          TextButton.icon(
                            onPressed: _busy || service.connectionStatus != CompanionConnectionStatus.connected
                                ? null
                                : () => _play(entry, true),
                            icon: const Icon(Icons.tv),
                            label: Text('在 ${service.selectedLabel} 继续'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _play(VideoHistoryCheckpoint checkpoint, bool tv) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (tv) {
        final service = ref.read(companionControllerProvider);
        final result = await service.handoff(
          CompanionContentRef(
            pluginId: checkpoint.pluginId,
            pluginVersion: checkpoint.pluginVersion,
            contentId: checkpoint.contentId,
            title: checkpoint.title,
            groupId: checkpoint.groupId,
            episodeId: checkpoint.episodeId,
            positionMs: checkpoint.position.inMilliseconds,
          ),
        );
        if (result.phase != CompanionCommandPhase.started) throw CompanionFailure(result.code ?? 'operation_failed');
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('TV 已实际起播。')));
      } else {
        await ref.read(companionLocalResumeLauncherProvider)(checkpoint);
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        unawaited(_load());
      }
    }
  }

  String _time(Duration value) => '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
}
