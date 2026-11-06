/// Application-level video preferences with remote-accessible visible choices.
/// Decoding/output and best-effort HLS ad filtering are durable host settings
/// sampled by the next video route; saves never reopen a live player.
/// Android renderer launch preferences are owned by native code; this panel
/// shows the active renderer and offers a restart only after the save succeeds.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_restart.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/media/application/android_rendering_settings.dart';
import 'package:mg_read/features/media/application/source_video_preferences.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

class ProfileVideoSettings extends ConsumerStatefulWidget {
  const ProfileVideoSettings({super.key});

  @override
  ConsumerState<ProfileVideoSettings> createState() => _ProfileVideoSettingsState();
}

class _ProfileVideoSettingsState extends ConsumerState<ProfileVideoSettings> {
  final _renderingSettings = const AndroidRenderingSettings();
  AndroidRenderingSnapshot? _rendering;
  bool _rendererLoading = false;
  bool _busy = false;
  String? _rendererError;
  String? _saveError;
  String? _notice;

  bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    if (_android) unawaited(_loadRenderer());
  }

  Future<void> _loadRenderer() async {
    setState(() {
      _rendererLoading = true;
      _rendererError = null;
    });
    try {
      final snapshot = await _renderingSettings.load();
      if (mounted) setState(() => _rendering = snapshot);
    } on Object {
      if (mounted) setState(() => _rendererError = '无法读取界面渲染设置，请重试。');
    } finally {
      if (mounted) setState(() => _rendererLoading = false);
    }
  }

  Future<void> _selectVideo(String value, {required bool decoder}) async {
    if (_busy) return;
    final settings = ref.read(appSettingsProvider);
    final adjustsOutput = decoder && value == 'software' && settings.get(AppSettingKeys.videoAndroidOutputMode) == 'surface';
    final adjustsDecoder = !decoder && value == 'surface' && settings.get(AppSettingKeys.videoDecoderMode) == 'software';
    setState(() {
      _busy = true;
      _saveError = null;
      _notice = null;
    });
    try {
      if (decoder) {
        await setSourceVideoDecoderPreference(settings, value);
      } else {
        await setSourceVideoOutputPreference(settings, value);
      }
      final flushed = await settings.flush();
      if (!flushed.persisted) throw StateError('Video settings were not persisted.');
      if (mounted) {
        setState(
          () => _notice = adjustsOutput
              ? '软件解码已同时切换为 GPU 输出。重新打开视频后生效。'
              : adjustsDecoder
              ? 'Surface 直连需要硬件解码，已同时切换为硬件优先。重新打开视频后生效。'
              : '已保存，重新打开视频后生效。',
        );
      }
    } on Object {
      if (mounted) setState(() => _saveError = '播放设置保存失败，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectRenderer(AndroidRendererMode mode) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _saveError = null;
      _notice = null;
    });
    try {
      final snapshot = await _renderingSettings.select(mode);
      if (mounted) setState(() => _rendering = snapshot);
    } on Object {
      if (mounted) setState(() => _saveError = '界面渲染设置保存失败，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectAdFilter(bool enabled) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _saveError = null;
      _notice = null;
    });
    try {
      final settings = ref.read(appSettingsProvider);
      await settings.set(AppSettingKeys.videoAdFilterEnabled, enabled);
      final flushed = await settings.flush();
      if (!flushed.persisted) throw StateError('Video settings were not persisted.');
      if (mounted) setState(() => _notice = '已保存，重新打开视频后生效。');
    } on Object {
      if (mounted) setState(() => _saveError = '播放设置保存失败，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restart() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _saveError = null;
    });
    try {
      await ref.read(appRestartProvider)();
    } on Object {
      if (mounted) setState(() => _saveError = '重启失败，请完全关闭应用后重新打开。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appSettingsStatusProvider);
    final settings = ref.watch(appSettingsProvider);
    final rendering = _rendering;
    final muted = AppThemeTokens.of(context).mutedText;
    return Column(
      key: const Key('profile-video-settings'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _choices(
          id: 'video-ad-filter',
          title: '视频广告过滤',
          description: '全局尝试过滤支持的 HLS 点播插片，无需数据源提供规则。无法确认的片段保留，画面内广告不受影响。重新打开视频后生效。',
          selected: settings.get(AppSettingKeys.videoAdFilterEnabled) ? 'on' : 'off',
          options: const [('on', '开启（推荐）'), ('off', '关闭')],
          onSelect: (value) => _selectAdFilter(value == 'on'),
        ),
        const SizedBox(height: AppSpacing.regular),
        _choices(
          id: 'video-decoder',
          title: '视频解码',
          description: '自动保留设备兼容策略；软件解码更依赖处理器性能。修改后重新打开视频生效。',
          selected: settings.get(AppSettingKeys.videoDecoderMode),
          options: const [('auto', '自动（推荐）'), ('hardware', '硬件优先'), ('software', '软件解码')],
          onSelect: (value) => _selectVideo(value, decoder: true),
        ),
        if (_android) ...[
          const SizedBox(height: AppSpacing.regular),
          _choices(
            id: 'video-output',
            title: '视频输出',
            description: '自动按设备选择兼容方式；Surface 直连需要硬件解码。修改后重新打开视频生效。',
            selected: settings.get(AppSettingKeys.videoAndroidOutputMode),
            options: const [('auto', '自动（推荐）'), ('gpu', 'GPU 输出'), ('surface', 'Surface 直连')],
            onSelect: (value) => _selectVideo(value, decoder: false),
          ),
          const SizedBox(height: AppSpacing.regular),
          _choices(
            id: 'android-renderer',
            title: '应用界面渲染',
            description: rendering == null
                ? '修改后需重启应用生效。${_rendererLoading ? '正在读取…' : ''}'
                : '当前：${switch (rendering.activeRenderer) {
                    'opengl' => 'OpenGL（兼容）',
                    'vulkan' => 'Vulkan',
                    _ => '系统默认',
                  }}。自动模式在电视上使用 OpenGL，其他设备使用系统默认。',
            selected: rendering?.selected.id,
            options: const [('auto', '自动（推荐）'), ('opengl', 'OpenGL（兼容）'), ('vulkan', 'Vulkan')],
            onSelect: rendering == null || _rendererLoading
                ? null
                : (value) => _selectRenderer(AndroidRendererMode.values.firstWhere((mode) => mode.id == value)),
          ),
          if (_rendererError != null) ...[
            Text(_rendererError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            TextButton(onPressed: _rendererLoading ? null : _loadRenderer, child: const Text('重新读取渲染设置')),
          ],
          if (rendering?.restartRequired ?? false) ...[
            const SizedBox(height: AppSpacing.compact),
            Text('界面渲染设置已保存，重启应用后生效。重启会中断当前播放。', style: TextStyle(color: muted)),
            OutlinedButton.icon(
              key: const Key('android-renderer-restart'),
              onPressed: _busy ? null : _restart,
              icon: const Icon(Icons.restart_alt_rounded),
              label: const Text('重启应用以生效'),
            ),
          ],
        ],
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.compact),
            child: Text(_notice!),
          ),
        if (_saveError != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.compact),
            child: Text(
              _saveError!,
              key: const Key('video-settings-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  Widget _choices({
    required String id,
    required String title,
    required String description,
    required String? selected,
    required List<(String, String)> options,
    required Future<void> Function(String)? onSelect,
  }) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.regular),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.compact),
          Text(description, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: AppSpacing.compact),
          Wrap(
            spacing: AppSpacing.compact,
            runSpacing: AppSpacing.compact,
            children: [
              for (final option in options)
                if (TvModeScope.isEnabled(context))
                  TvFocusable(
                    key: Key('$id-${option.$1}'),
                    selected: selected == option.$1,
                    onPressed: onSelect == null
                        ? null
                        : () {
                            if (!_busy) unawaited(onSelect(option.$1));
                          },
                    child: Text(option.$2),
                  )
                else
                  ChoiceChip(
                    key: Key('$id-${option.$1}'),
                    label: Text(option.$2),
                    selected: selected == option.$1,
                    onSelected: _busy || onSelect == null ? null : (_) => unawaited(onSelect(option.$1)),
                  ),
            ],
          ),
        ],
      ),
    ),
  );
}
