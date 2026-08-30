/// Profile page that owns editing the shared explicit proxy endpoint.
///
/// The page persists no credentials and does not make test network requests.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

final class NetworkProxySettingsPage extends ConsumerStatefulWidget {
  const NetworkProxySettingsPage({required this.onBackRequested, super.key});

  final VoidCallback onBackRequested;

  @override
  ConsumerState<NetworkProxySettingsPage> createState() => _NetworkProxySettingsPageState();
}

final class _NetworkProxySettingsPageState extends ConsumerState<NetworkProxySettingsPage> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late NetworkProxyProtocol _protocol;
  late Map<NetworkProxyTraffic, bool> _enabled;
  bool _initialized = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController();
    _portController = TextEditingController();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preferences = ref.watch(networkProxySettingsProvider);
    if (!_initialized) _load(preferences);
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              AppSecondaryPageTopBar(title: '代理设置', onBack: widget.onBackRequested),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AppDetailMetrics.horizontalPadding,
                    AppSpacing.section,
                    AppDetailMetrics.horizontalPadding,
                    AppSpacing.profileContentBottomSafeDistance,
                  ),
                  children: <Widget>[
                    Text('代理地址', style: theme.textTheme.titleMedium),
                    const SizedBox(height: AppSpacing.compact),
                    DropdownButtonFormField<NetworkProxyProtocol>(
                      key: const Key('network-proxy-protocol'),
                      initialValue: _protocol,
                      decoration: const InputDecoration(labelText: '协议'),
                      items: NetworkProxyProtocol.values
                          .map((value) => DropdownMenuItem(value: value, child: Text(value.name.toUpperCase())))
                          .toList(growable: false),
                      onChanged: _saving ? null : (value) => setState(() => _protocol = value!),
                    ),
                    const SizedBox(height: AppSpacing.compact),
                    TextField(
                      key: const Key('network-proxy-host'),
                      controller: _hostController,
                      enabled: !_saving,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: '地址', hintText: '127.0.0.1'),
                    ),
                    const SizedBox(height: AppSpacing.compact),
                    TextField(
                      key: const Key('network-proxy-port'),
                      controller: _portController,
                      enabled: !_saving,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '端口', hintText: '9000'),
                    ),
                    const SizedBox(height: AppSpacing.section),
                    Text('按流量类型启用', style: theme.textTheme.titleMedium),
                    const SizedBox(height: AppSpacing.compact),
                    Card(
                      child: Column(
                        children: <Widget>[
                          for (final traffic in NetworkProxyTraffic.values)
                            SwitchListTile(
                              key: Key('network-proxy-${traffic.name}'),
                              title: Text(_label(traffic)),
                              subtitle: Text(_description(traffic)),
                              value: _enabled[traffic] ?? false,
                              onChanged: _saving || !_isSupported(traffic)
                                  ? null
                                  : (value) => setState(() => _enabled = <NetworkProxyTraffic, bool>{..._enabled, traffic: value}),
                            ),
                        ],
                      ),
                    ),
                    if (_error != null) ...<Widget>[
                      const SizedBox(height: AppSpacing.comfortable),
                      Text(
                        _error!,
                        key: const Key('network-proxy-error'),
                        style: theme.textTheme.bodySmall?.copyWith(color: tokens.warning),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.section),
                    FilledButton(
                      key: const Key('network-proxy-save'),
                      onPressed: _saving ? null : _save,
                      child: Text(_saving ? '正在保存…' : '保存代理设置'),
                    ),
                    const SizedBox(height: AppSpacing.compact),
                    Text(
                      '默认 HTTP://127.0.0.1:9000。不保存账号或密码；保存后立即用于新连接，已经建立的播放连接会在下次分片或重新打开时切换。',
                      style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _load(NetworkProxySettings value) {
    _initialized = true;
    _protocol = value.protocol;
    _enabled = Map<NetworkProxyTraffic, bool>.of(value.enabled);
    _hostController.text = value.host;
    _portController.text = value.port.toString();
  }

  Future<void> _save() async {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text);
    if (host.isEmpty || host.contains(RegExp(r'[\\s/@]')) || port == null || port < 1 || port > 65535) {
      setState(() => _error = '请输入有效的代理地址和 1–65535 端口。');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final value = NetworkProxySettings(protocol: _protocol, host: host, port: port, enabled: _enabled);
      await saveNetworkProxySettings(ref.read(appSettingsProvider), value);
      final proxyManager = ref.read(flutterNetworkProxyManagerProvider)..update(value);
      await ref
          .read(pluginRuntimeFacadeProvider)
          .configureFlutterTransportProxy(await proxyManager.proxyUriFor(NetworkProxyTraffic.runtime));
      if (mounted) {
        setState(() => _saving = false);
      }
    } on Object {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '代理设置保存失败，请稍后重试。';
        });
      }
    }
  }
}

String _label(NetworkProxyTraffic value) => switch (value) {
  NetworkProxyTraffic.runtime => '与书源 Runtime 通讯',
  NetworkProxyTraffic.manga => '漫画',
  NetworkProxyTraffic.video => '视频',
  NetworkProxyTraffic.audio => '音频',
};

String _description(NetworkProxyTraffic value) => switch (value) {
  NetworkProxyTraffic.runtime =>
    Platform.isAndroid ? 'Android Runtime 在应用进程内，没有可代理的 Flutter 网络链路' : '仅 Flutter 到 Runtime 的通讯，不修改 Node.js 请求',
  NetworkProxyTraffic.manga => 'Flutter 下载的漫画图片与相关资源',
  NetworkProxyTraffic.video => 'MediaKit 加载的视频清单与分片',
  NetworkProxyTraffic.audio => 'MediaKit 加载的音频清单与分片',
};

bool _isSupported(NetworkProxyTraffic value) => value != NetworkProxyTraffic.runtime || !Platform.isAndroid;
