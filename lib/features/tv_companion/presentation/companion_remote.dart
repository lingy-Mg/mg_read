/// Touch remote driven entirely by receiver snapshots. Slider previews remain
/// local; a dropped connection cancels pending previews/holds, never playback.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import '../application/companion_controller.dart';
import '../domain/companion_command.dart';
import '../domain/companion_models.dart';
import 'companion_messages.dart';
import 'companion_text_dialog.dart';

class CompanionRemote extends StatefulWidget {
  const CompanionRemote({required this.service, super.key});
  final CompanionController service;
  @override
  State<CompanionRemote> createState() => _CompanionRemoteState();
}

class _CompanionRemoteState extends State<CompanionRemote> {
  Timer? _seekTimer, _holdTimer;
  final Map<CompanionCommandType, Timer> _volumeTimers = {};
  final Map<CompanionCommandType, double> _volumePreviews = {};
  int _seekGeneration = 0;
  int _holdGeneration = 0;
  Future<CompanionInteraction>? _seekInteraction;
  final Map<CompanionCommandType, Future<CompanionInteraction>> _volumeInteractions = {};
  double? _dragPosition;
  String? _message;
  bool _sendingHold = false;
  bool _inputOpen = false;
  CompanionController get service => widget.service;
  Future<CompanionInteraction> _beginInteraction() {
    final future = service.beginInteraction();
    future.ignore();
    return future;
  }

  @override
  void dispose() {
    _seekTimer?.cancel();
    _holdTimer?.cancel();
    for (final timer in _volumeTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  Future<void> _send(CompanionCommandType type, [Map<String, Object?> args = const {}]) async {
    try {
      final result = await service.command(type, arguments: args);
      if (!mounted) return;
      if (result.phase != CompanionCommandPhase.applied && result.phase != CompanionCommandPhase.started) {
        setState(() => _message = companionErrorText(result.code));
      }
    } on Object catch (error) {
      if (mounted) setState(() => _message = companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'));
    }
  }

  void _seek(double value, {bool finalValue = false}) {
    _seekTimer?.cancel();
    final generation = ++_seekGeneration;
    setState(() => _dragPosition = value);
    final interaction = _seekInteraction ??= _beginInteraction();
    Future<void> send() async {
      await _sendInteraction(interaction, CompanionCommandType.seek, {
        'positionMs': value.round(),
      }, isCurrent: () => generation == _seekGeneration);
      if (mounted && generation == _seekGeneration && finalValue) {
        setState(() {
          _dragPosition = null;
          _seekInteraction = null;
        });
      }
    }

    if (finalValue) {
      unawaited(send());
    } else {
      _seekTimer = Timer(const Duration(milliseconds: 250), () => unawaited(send()));
    }
  }

  void _volume(CompanionCommandType type, double value, {bool finalValue = false}) {
    _volumeTimers.remove(type)?.cancel();
    setState(() => _volumePreviews[type] = value);
    final interaction = _volumeInteractions.putIfAbsent(type, _beginInteraction);
    Future<void> send() async {
      await _sendInteraction(interaction, type, {'volume': value});
      if (mounted && finalValue) {
        setState(() {
          _volumePreviews.remove(type);
          _volumeInteractions.remove(type);
        });
      }
    }

    if (finalValue) {
      unawaited(send());
    } else {
      _volumeTimers[type] = Timer(const Duration(milliseconds: 250), () => unawaited(send()));
    }
  }

  Future<void> _sendInteraction(
    Future<CompanionInteraction> interaction,
    CompanionCommandType type,
    Map<String, Object?> args, {
    bool Function()? isCurrent,
  }) async {
    try {
      final token = await interaction;
      if (!mounted || isCurrent?.call() == false) return;
      final result = await service.interactionCommand(token, type, arguments: args);
      if (mounted && result.phase != CompanionCommandPhase.applied && result.phase != CompanionCommandPhase.started) {
        setState(() => _message = companionErrorText(result.code));
      }
    } on Object catch (error) {
      if (mounted) setState(() => _message = companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'));
    }
  }

  Widget _direction(String key, IconData icon, String label, bool enabled) => GestureDetector(
    onLongPressStart: !enabled || key == 'confirm'
        ? null
        : (_) {
            _holdTimer?.cancel();
            final generation = ++_holdGeneration;
            final interaction = _beginInteraction();
            _holdTimer = Timer.periodic(const Duration(milliseconds: 200), (_) async {
              if (_sendingHold || !service.hasControl) return;
              _sendingHold = true;
              try {
                await _sendInteraction(interaction, CompanionCommandType.navigate, {
                  'key': key,
                }, isCurrent: () => generation == _holdGeneration && _holdTimer?.isActive == true);
              } finally {
                _sendingHold = false;
              }
            });
          },
    onLongPressEnd: (_) {
      _holdGeneration++;
      _holdTimer?.cancel();
    },
    onLongPressCancel: () {
      _holdGeneration++;
      _holdTimer?.cancel();
    },
    child: SizedBox(
      width: 72,
      height: 64,
      child: IconButton.filledTonal(
        tooltip: label,
        onPressed: enabled ? () => _send(CompanionCommandType.navigate, {'key': key}) : null,
        icon: Icon(icon),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: service,
    builder: (context, _) {
      final state = service.remoteState;
      final connected = service.connectionStatus == CompanionConnectionStatus.connected;
      final enabled = connected && !service.stale;
      if (!enabled) {
        _seekTimer?.cancel();
        _holdTimer?.cancel();
        _dragPosition = null;
        _seekInteraction = null;
        _volumeInteractions.clear();
        for (final timer in _volumeTimers.values) {
          timer.cancel();
        }
        _volumeTimers.clear();
        _volumePreviews.clear();
      }
      final title = service.selectedDeviceId == null ? '未选择 TV' : service.selectedLabel;
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          Text(
            !connected
                ? '连接未建立'
                : service.stale
                ? '状态更新延迟，控制已暂停'
                : service.hasControl
                ? '实时连接 · 本机正在控制'
                : state?.controllerId == null
                ? '实时连接 · 点击操作取得控制权'
                : '实时连接 · TV 或另一台手机正在操作',
          ),
          if (service.remoteStateAt != null) Text('状态时间：${service.remoteStateAt!.toLocal().toString().substring(11, 19)}'),
          if (_message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(_message!)),
          if (service.errorCode != null) Text(companionErrorText(service.errorCode)),
          const SizedBox(height: 20),
          Text(state?.content?.title ?? 'TV 当前未播放视频', style: Theme.of(context).textTheme.titleLarge),
          if (state?.content case final content?) Text('分组：${content.groupId} · 集数：${content.episodeId}'),
          Text(_statusLabel(state?.status)),
          if (state?.saveFailure == true) const Text('TV 播放中，进度尚未保存。请检查 TV 存储。'),
          if (state?.failureCode != null) Text(companionErrorText(state?.failureCode)),
          if (service.lastReceipt case final receipt?)
            Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(_phaseLabel(receipt))),
          if (state != null && state.durationMs > 0) ...[
            Slider(
              value: (_dragPosition ?? state.positionMs.toDouble()).clamp(0, state.durationMs.toDouble()),
              min: 0,
              max: state.durationMs.toDouble(),
              onChanged: enabled ? (value) => _seek(value) : null,
              onChangeEnd: enabled ? (value) => _seek(value, finalValue: true) : null,
            ),
            Text('${_time((_dragPosition ?? state.positionMs).toInt())} / ${_time(state.durationMs)}'),
          ],
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              IconButton(
                tooltip: '上一集',
                onPressed: enabled && state?.hasPrevious == true ? () => _send(CompanionCommandType.previousEpisode) : null,
                icon: const Icon(Icons.skip_previous),
              ),
              IconButton(
                tooltip: '后退 10 秒',
                onPressed: enabled && (state?.durationMs ?? 0) > 0
                    ? () => _seek(((state!.positionMs - 10000).clamp(0, state.durationMs)).toDouble(), finalValue: true)
                    : null,
                icon: const Icon(Icons.replay_10),
              ),
              IconButton.filled(
                tooltip: state?.playing == true ? '暂停' : '播放',
                onPressed: enabled && state?.content != null
                    ? () => _send(state!.playing ? CompanionCommandType.pause : CompanionCommandType.play)
                    : null,
                icon: Icon(state?.playing == true ? Icons.pause : Icons.play_arrow),
                iconSize: 40,
              ),
              IconButton(
                tooltip: '前进 10 秒',
                onPressed: enabled && (state?.durationMs ?? 0) > 0
                    ? () => _seek(((state!.positionMs + 10000).clamp(0, state.durationMs)).toDouble(), finalValue: true)
                    : null,
                icon: const Icon(Icons.forward_10),
              ),
              IconButton(
                tooltip: '下一集',
                onPressed: enabled && state?.hasNext == true ? () => _send(CompanionCommandType.nextEpisode) : null,
                icon: const Icon(Icons.skip_next),
              ),
            ],
          ),
          if (state?.content != null) ...[
            const SizedBox(height: 16),
            DropdownButtonFormField<double>(
              initialValue: state!.rate,
              decoration: const InputDecoration(labelText: '播放倍速'),
              items: [
                for (final rate in {.25, .5, .75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, state.rate}.toList()..sort())
                  DropdownMenuItem(value: rate, child: Text('${rate}x')),
              ],
              onChanged: enabled
                  ? (value) {
                      if (value != null) unawaited(_send(CompanionCommandType.setRate, {'rate': value}));
                    }
                  : null,
            ),
            const SizedBox(height: 12),
            const Text('应用播放音量'),
            TextButton.icon(
              onPressed: enabled ? () => _send(CompanionCommandType.setMuted, {'muted': state.volume > 0}) : null,
              icon: Icon(state.volume == 0 ? Icons.volume_off : Icons.volume_up),
              label: Text(state.volume == 0 ? '取消应用静音' : '应用静音'),
            ),
            Slider(
              value: (_volumePreviews[CompanionCommandType.setVolume] ?? state.volume).clamp(0, 100),
              min: 0,
              max: 100,
              onChanged: enabled ? (value) => _volume(CompanionCommandType.setVolume, value) : null,
              onChangeEnd: enabled ? (value) => _volume(CompanionCommandType.setVolume, value, finalValue: true) : null,
            ),
            if (state.canSystemVolume) ...[
              const Text('TV 系统媒体音量'),
              Slider(
                value: (_volumePreviews[CompanionCommandType.setSystemVolume] ?? state.systemVolume ?? 0).clamp(0, 100),
                min: 0,
                max: 100,
                onChanged: enabled ? (value) => _volume(CompanionCommandType.setSystemVolume, value) : null,
                onChangeEnd: enabled ? (value) => _volume(CompanionCommandType.setSystemVolume, value, finalValue: true) : null,
              ),
            ],
            TextButton(onPressed: enabled ? () => _episodes(state) : null, child: const Text('选集 / 分组')),
          ],
          const Divider(height: 32),
          Center(
            child: Column(
              children: [
                _direction('up', Icons.keyboard_arrow_up, '向上', enabled),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _direction('left', Icons.keyboard_arrow_left, '向左', enabled),
                    _direction('confirm', Icons.check, '确认', enabled),
                    _direction('right', Icons.keyboard_arrow_right, '向右', enabled),
                  ],
                ),
                _direction('down', Icons.keyboard_arrow_down, '向下', enabled),
              ],
            ),
          ),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            children: [
              OutlinedButton.icon(
                onPressed: enabled ? () => _send(CompanionCommandType.navigate, {'key': 'back'}) : null,
                icon: const Icon(Icons.arrow_back),
                label: const Text('TV 返回'),
              ),
              OutlinedButton.icon(onPressed: enabled ? _input : null, icon: const Icon(Icons.keyboard), label: const Text('给 TV 搜索框输入')),
              if (enabled && !service.hasControl) TextButton(onPressed: () => _takeControl(), child: const Text('请求接管')),
            ],
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            children: [
              TextButton(onPressed: connected ? () => service.disconnect() : null, child: const Text('断开遥控，TV 继续播放')),
              TextButton(onPressed: enabled && state?.content != null ? () => _exit() : null, child: const Text('退出 TV 播放')),
            ],
          ),
        ],
      );
    },
  );
  Future<void> _takeControl() async {
    try {
      await service.request('requestControl');
      if (mounted) setState(() => _message = '请在 TV 上确认接管请求。');
    } on Object {
      if (mounted) setState(() => _message = '请求未发送，请重试。');
    }
  }

  Future<void> _exit() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出 TV 播放？'),
        content: const Text('TV 会保存进度并退出当前视频。仅断开遥控不会停止播放。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('退出播放')),
        ],
      ),
    );
    if (confirmed == true) await _send(CompanionCommandType.exitPlayback);
  }

  Future<void> _input() async {
    if (_inputOpen) return;
    setState(() => _inputOpen = true);
    try {
      await showCompanionTextDialog(context, service);
    } on Object catch (error) {
      if (mounted) setState(() => _message = companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'));
    } finally {
      if (mounted) setState(() => _inputOpen = false);
    }
  }

  Future<void> _episodes(CompanionPlaybackSnapshot state) async {
    final content = state.content!;
    try {
      Map<String, Object?>? group;
      var groupOffset = 0;
      while (mounted) {
        final catalog = await service.request(
          'catalog',
          arguments: {'pluginId': content.pluginId, 'contentId': content.contentId, 'offset': groupOffset},
        );
        if (!mounted) return;
        final choice = await showDialog<Object>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('选择分组'),
            children: [
              for (final raw in catalog['groups'] as List)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, companionMap(raw)),
                  child: Text(companionMap(raw)['title'] as String),
                ),
              if (catalog['nextOffset'] != null)
                SimpleDialogOption(onPressed: () => Navigator.pop(context, 'more'), child: const Text('下一页分组')),
            ],
          ),
        );
        if (choice == 'more') {
          groupOffset = catalog['nextOffset'] as int;
          continue;
        }
        if (choice != null) group = companionMap(choice);
        break;
      }
      if (group == null || !mounted) return;
      final selectedGroup = group;
      var offset = 0;
      while (mounted) {
        final episodes = await service.request(
          'episodes',
          arguments: {'pluginId': content.pluginId, 'contentId': content.contentId, 'groupId': selectedGroup['id'], 'offset': offset},
        );
        if (!mounted) return;
        final selected = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text(selectedGroup['title'] as String),
            children: [
              for (final raw in episodes['items'] as List)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, companionMap(raw)['id'] as String),
                  child: Text(companionMap(raw)['title'] as String),
                ),
              if (episodes['nextOffset'] != null)
                SimpleDialogOption(onPressed: () => Navigator.pop(context, '__more__'), child: const Text('下一页')),
            ],
          ),
        );
        if (selected == '__more__') {
          offset = episodes['nextOffset'] as int;
          continue;
        }
        if (selected != null) await _send(CompanionCommandType.selectEpisode, {'groupId': selectedGroup['id'], 'episodeId': selected});
        return;
      }
    } on Object catch (error) {
      if (mounted) setState(() => _message = companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'));
    }
  }

  String _time(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  String _statusLabel(String? status) => switch (status) {
    'playing' => 'TV 正在播放',
    'paused' => 'TV 已暂停',
    'buffering' => 'TV 正在缓冲',
    'preparing' => 'TV 正在准备内容',
    'failed' => 'TV 播放失败',
    'completed' => '本集播放完成',
    _ => 'TV 待机',
  };
  String _phaseLabel(CompanionReceipt receipt) => switch (receipt.phase) {
    CompanionCommandPhase.received => '命令已收到',
    CompanionCommandPhase.accepted => '命令已受理',
    CompanionCommandPhase.preparing => 'TV 正在准备',
    CompanionCommandPhase.resolving => 'TV 正在解析来源',
    CompanionCommandPhase.buffering => 'TV 正在等待可用画面',
    CompanionCommandPhase.started => 'TV 已实际起播',
    CompanionCommandPhase.applied => '操作已由 TV 确认',
    _ => companionErrorText(receipt.code),
  };
}
