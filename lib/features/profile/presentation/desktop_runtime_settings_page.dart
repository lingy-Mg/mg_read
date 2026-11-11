/// Desktop JavaScript host choice. Saves through Runtime-owned launch settings;
/// active/selected stay distinct until a full process restart. Node remains
/// available as a compatibility option and shares installed sources with Bun.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/app_restart.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

final desktopRuntimeSettingsProvider = Provider<DesktopRuntimeSettings>((ref) => DesktopRuntimeSettings.instance);

class DesktopRuntimeSettingsPage extends ConsumerStatefulWidget {
  const DesktopRuntimeSettingsPage({required this.onBackRequested, super.key});
  final VoidCallback onBackRequested;

  @override
  ConsumerState<DesktopRuntimeSettingsPage> createState() => _DesktopRuntimeSettingsPageState();
}

class _DesktopRuntimeSettingsPageState extends ConsumerState<DesktopRuntimeSettingsPage> {
  bool _busy = false;
  String? _error;

  String _label(DesktopRuntimeBackend backend) => backend == DesktopRuntimeBackend.bun ? 'Bun' : 'Node.js';

  Future<void> _select(DesktopRuntimeBackend backend) async {
    final settings = ref.read(desktopRuntimeSettingsProvider);
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
          content: Text('已选择 ${_label(backend)}。重启后启用，已安装的数据源保留。当前阅读、播放和下载会中断。'),
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
          _error = '自动重启失败，请重试，或完全退出 App 后重新打开。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(desktopRuntimeSettingsProvider);
    return Scaffold(
      body: SafeArea(
        child: AppSecondaryPageContent(
          child: Column(
            children: [
              AppSecondaryPageTopBar(title: 'JavaScript 运行时', onBack: widget.onBackRequested),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(AppSpacing.regular),
                  children: [
                    Text('当前运行：${_label(settings.active)}', key: const Key('desktop-runtime-active')),
                    const SizedBox(height: AppSpacing.regular),
                    const Text('两种运行时共用已安装的数据源和配置，切换后无需重新导入。每次只运行所选的一种；遇到数据源兼容问题时，可切回 Node.js。'),
                    const SizedBox(height: AppSpacing.regular),
                    for (final backend in DesktopRuntimeBackend.values)
                      Card(
                        child: ListTile(
                          key: Key('desktop-runtime-${backend.name}'),
                          title: Text(_label(backend)),
                          subtitle: Text(
                            backend == DesktopRuntimeBackend.node
                                ? '26.10.0 · 默认运行时'
                                : settings.supportsBun
                                ? '${DesktopRuntimeSettings.bunVersion} · 随 App 内置'
                                : '当前安装包缺少 Bun，请重新安装完整版本',
                          ),
                          selected: settings.selected == backend,
                          trailing: Icon(settings.selected == backend ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                          enabled: !_busy && (backend != DesktopRuntimeBackend.bun || settings.supportsBun),
                          onTap: () => _select(backend),
                        ),
                      ),
                    if (settings.restartRequired) ...[
                      const SizedBox(height: AppSpacing.regular),
                      Text('待启用：${_label(settings.selected)}，重启后生效。', key: const Key('desktop-runtime-pending')),
                      const SizedBox(height: AppSpacing.regular),
                      FilledButton(onPressed: _busy ? null : _restart, child: const Text('立即重启')),
                    ],
                    if (_busy) const LinearProgressIndicator(),
                    if (_error != null) Text(_error!, key: const Key('desktop-runtime-error')),
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
