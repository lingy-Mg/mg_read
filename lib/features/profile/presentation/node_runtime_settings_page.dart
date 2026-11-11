/// Android Node host selection. Persist via the Runtime's typed launch settings;
/// keep the active host unchanged until the user restarts the app process.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/app_restart.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

final androidNodeRuntimeSettingsProvider = Provider<AndroidNodeRuntimeSettings>((ref) => AndroidNodeRuntimeSettings.instance);

class NodeRuntimeSettingsPage extends ConsumerStatefulWidget {
  const NodeRuntimeSettingsPage({required this.onBackRequested, super.key});

  final VoidCallback onBackRequested;

  @override
  ConsumerState<NodeRuntimeSettingsPage> createState() => _NodeRuntimeSettingsPageState();
}

class _NodeRuntimeSettingsPageState extends ConsumerState<NodeRuntimeSettingsPage> {
  bool _busy = false;
  String? _error;

  String _label(AndroidNodeBackend backend) => switch (backend) {
    AndroidNodeBackend.javet => 'Javet 内嵌运行时',
    AndroidNodeBackend.nodeProcess => 'Node.js 独立进程',
  };

  Future<void> _select(AndroidNodeBackend backend) async {
    final settings = ref.read(androidNodeRuntimeSettingsProvider);
    if (_busy || settings.selected == backend) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await settings.select(backend);
      if (!mounted) return;
      setState(() => _busy = false);
      if (!settings.restartRequired) return;
      final restart = await showDialog<bool>(
        context: context,
        animationStyle: AppMotion.overlayStyle(context),
        builder: (context) => AlertDialog(
          title: const Text('重启后生效'),
          content: Text('已选择${_label(backend)}。重启 App 后启用，当前阅读、播放和下载会中断。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('稍后重启')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('立即重启')),
          ],
        ),
      );
      if (restart == true && mounted) await _restart();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '保存失败，请重试。';
        });
      }
    }
  }

  Future<void> _restart() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(appRestartProvider)();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '自动重启失败，请重试，或完全关闭 App 后重新打开。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(androidNodeRuntimeSettingsProvider);
    return Scaffold(
      body: SafeArea(
        child: AppSecondaryPageContent(
          child: Column(
            children: [
              AppSecondaryPageTopBar(title: 'Node.js 运行时', onBack: widget.onBackRequested),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(AppSpacing.regular),
                  children: [
                    Text('当前运行：${_label(settings.active)}', key: const Key('node-runtime-active')),
                    const SizedBox(height: AppSpacing.regular),
                    Text(settings.supportsJavet ? '可选择当前设备支持的运行时。切换将在重启后生效，已安装的数据源保留。' : '当前设备使用 Node.js 独立进程运行数据源。'),
                    const SizedBox(height: AppSpacing.regular),
                    for (final backend in AndroidNodeBackend.values)
                      Card(
                        child: ListTile(
                          key: Key('node-runtime-${backend.name}'),
                          title: Text(_label(backend)),
                          subtitle: Text(
                            backend == AndroidNodeBackend.javet
                                ? settings.supportsJavet
                                      ? '在 App 进程内运行'
                                      : '当前设备不支持此运行时'
                                : settings.supportsNodeProcess
                                ? '在独立进程中运行'
                                : '当前安装包不包含此运行时',
                          ),
                          trailing: Icon(settings.selected == backend ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                          enabled: !_busy && (backend == AndroidNodeBackend.javet ? settings.supportsJavet : settings.supportsNodeProcess),
                          onTap: () => _select(backend),
                        ),
                      ),
                    if (settings.restartRequired) ...[
                      const SizedBox(height: AppSpacing.regular),
                      Text('待启用：${_label(settings.selected)}，重启后生效。', key: const Key('node-runtime-pending')),
                      const SizedBox(height: AppSpacing.regular),
                      FilledButton(onPressed: _busy ? null : _restart, child: const Text('立即重启')),
                    ],
                    if (_busy) const LinearProgressIndicator(),
                    if (_error != null) Text(_error!, key: const Key('node-runtime-error')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
