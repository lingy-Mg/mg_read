/// Profile page that owns editing the shared explicit proxy endpoint.
///
/// The page does not make test network requests.
/// Its cards only present routing intent; applying and persisting the endpoint
/// remains delegated to the app-owned proxy boundaries below.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/network_proxy/application/player_local_proxy_policy.dart';
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
  bool _forcePlayerLocalProxy = false;
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
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              AppSecondaryPageTopBar(title: '代理设置', onBack: widget.onBackRequested),
              Expanded(
                child: ListView(
                  key: const Key('network-proxy-content'),
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(
                    AppDetailMetrics.horizontalPadding,
                    AppSpacing.regular,
                    AppDetailMetrics.horizontalPadding,
                    AppSpacing.section,
                  ),
                  children: <Widget>[
                    _ProxySummaryCard(
                      protocol: _protocol,
                      host: _hostController.text,
                      port: _portController.text,
                      enabledCount: _enabled.values.where((bool value) => value).length + (_forcePlayerLocalProxy ? 1 : 0),
                    ),
                    const SizedBox(height: AppSpacing.section),
                    const _ProxySectionHeading(title: '自定义代理', description: '仅供下方已开启的流量覆盖系统代理'),
                    const SizedBox(height: AppSpacing.regular),
                    _ProxyEndpointCard(
                      protocol: _protocol,
                      hostController: _hostController,
                      portController: _portController,
                      enabled: !_saving,
                      onProtocolChanged: (NetworkProxyProtocol value) => setState(() => _protocol = value),
                      onEndpointChanged: () => setState(() {}),
                    ),
                    const SizedBox(height: AppSpacing.section),
                    const _ProxySectionHeading(title: '系统代理', description: '未启用自定义代理的流量自动跟随系统设置'),
                    const SizedBox(height: AppSpacing.regular),
                    const _SystemProxyCard(),
                    const SizedBox(height: AppSpacing.section),
                    const _ProxySectionHeading(title: '自定义代理范围', description: '开启后使用上方地址，关闭时继续使用系统代理'),
                    const SizedBox(height: AppSpacing.regular),
                    _ProxyTrafficCard(
                      enabled: _enabled,
                      saving: _saving,
                      onChanged: (NetworkProxyTraffic traffic, bool value) {
                        setState(() => _enabled = <NetworkProxyTraffic, bool>{..._enabled, traffic: value});
                      },
                    ),
                    const SizedBox(height: AppSpacing.section),
                    const _ProxySectionHeading(title: '播放器本地链路', description: '控制播放器访问 Runtime 本地资源地址时是否强制经过代理'),
                    const SizedBox(height: AppSpacing.regular),
                    _PlayerLocalProxyCard(
                      value: _forcePlayerLocalProxy,
                      enabled:
                          !_saving &&
                          Platform.isWindows &&
                          _protocol == NetworkProxyProtocol.http &&
                          ((_enabled[NetworkProxyTraffic.video] ?? false) || (_enabled[NetworkProxyTraffic.audio] ?? false)),
                      onChanged: (bool value) => setState(() => _forcePlayerLocalProxy = value),
                    ),
                    if (_error != null) ...<Widget>[
                      const SizedBox(height: AppSpacing.comfortable),
                      _ProxyNotice(message: _error!, warning: true, noticeKey: const Key('network-proxy-error')),
                    ],
                    const SizedBox(height: AppSpacing.comfortable),
                    const _ProxyNotice(
                      message: 'MgRead 默认跟随系统代理。视频和音频开关控制播放器到 Runtime 本地地址的链路；强制本地代理会从应用进程的 NO_PROXY 中临时移除 loopback，关闭后恢复。',
                    ),
                  ],
                ),
              ),
              _ProxySaveBar(saving: _saving, onPressed: _saving ? null : _save),
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
    _forcePlayerLocalProxy = value.forcePlayerLocalProxy;
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
    final mediaProxyEnabled = (_enabled[NetworkProxyTraffic.video] ?? false) || (_enabled[NetworkProxyTraffic.audio] ?? false);
    if (mediaProxyEnabled && _protocol != NetworkProxyProtocol.http) {
      setState(() => _error = 'MediaKit 的播放器本地链路只支持 HTTP 代理，请把代理协议切换为 HTTP。');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final value = NetworkProxySettings(
        protocol: _protocol,
        host: host,
        port: port,
        forcePlayerLocalProxy: _forcePlayerLocalProxy,
        enabled: _enabled,
      );
      await saveNetworkProxySettings(ref.read(appSettingsProvider), value);
      final proxyManager = ref.read(flutterNetworkProxyManagerProvider)..update(value);
      String? applyWarning;
      try {
        ref.read(playerLocalProxyPolicyControllerProvider).update(value);
        final runtime = ref.read(pluginRuntimeFacadeProvider);
        await runtime.configureNodeEnvironmentProxy(true);
        await runtime.configurePluginHttpProxy(await proxyManager.runtimeSourceProxyUri());
      } on Object {
        applyWarning = '设置已保存；当前 Node Runtime 代理切换失败，Runtime 下次启动时会重新应用。';
      }
      if (mounted) {
        setState(() {
          _saving = false;
          _error = applyWarning;
        });
        if (applyWarning == null) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(content: Text('代理设置已保存')));
        }
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

class _ProxySummaryCard extends StatelessWidget {
  const _ProxySummaryCard({required this.protocol, required this.host, required this.port, required this.enabledCount});

  final NetworkProxyProtocol protocol;
  final String host;
  final String port;
  final int enabledCount;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final String endpointHost = host.trim().isEmpty ? '127.0.0.1' : host.trim();
    final String endpointPort = port.trim().isEmpty ? '9000' : port.trim();
    return DecoratedBox(
      key: const Key('network-proxy-summary'),
      decoration: BoxDecoration(
        color: tokens.featureSurface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.accent.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.comfortable),
        child: Row(
          children: <Widget>[
            _ProxyIconBadge(icon: Icons.lan_rounded, background: tokens.accent, foreground: theme.colorScheme.onPrimary, size: 48),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('网络代理', style: theme.textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.unit),
                  Text(
                    '${protocol.name.toUpperCase()}://$endpointHost:$endpointPort',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.compact),
            DecoratedBox(
              decoration: BoxDecoration(color: tokens.surface, borderRadius: AppRadii.pill),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.regular, vertical: AppSpacing.compact),
                child: Text(
                  enabledCount == 0 ? '使用系统' : '自定义 $enabledCount 项',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: enabledCount == 0 ? tokens.mutedText : tokens.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProxySectionHeading extends StatelessWidget {
  const _ProxySectionHeading({required this.title, required this.description});

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.unit),
        Text(description, style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
      ],
    );
  }
}

class _ProxyEndpointCard extends StatelessWidget {
  const _ProxyEndpointCard({
    required this.protocol,
    required this.hostController,
    required this.portController,
    required this.enabled,
    required this.onProtocolChanged,
    required this.onEndpointChanged,
  });

  final NetworkProxyProtocol protocol;
  final TextEditingController hostController;
  final TextEditingController portController;
  final bool enabled;
  final ValueChanged<NetworkProxyProtocol> onProtocolChanged;
  final VoidCallback onEndpointChanged;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      key: const Key('network-proxy-endpoint-card'),
      decoration: _cardDecoration(tokens),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.comfortable),
        child: Column(
          children: <Widget>[
            DropdownButtonFormField<NetworkProxyProtocol>(
              key: const Key('network-proxy-protocol'),
              initialValue: protocol,
              isExpanded: true,
              decoration: _fieldDecoration(context, label: '代理协议', icon: Icons.swap_horiz_rounded),
              items: NetworkProxyProtocol.values
                  .map(
                    (NetworkProxyProtocol value) =>
                        DropdownMenuItem<NetworkProxyProtocol>(value: value, child: Text(value.name.toUpperCase())),
                  )
                  .toList(growable: false),
              onChanged: enabled ? (NetworkProxyProtocol? value) => onProtocolChanged(value!) : null,
            ),
            const SizedBox(height: AppSpacing.regular),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: TextField(
                    key: const Key('network-proxy-host'),
                    controller: hostController,
                    enabled: enabled,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => onEndpointChanged(),
                    decoration: _fieldDecoration(context, label: '服务器地址', hint: '127.0.0.1', icon: Icons.dns_outlined),
                  ),
                ),
                const SizedBox(width: AppSpacing.regular),
                Expanded(
                  flex: 2,
                  child: TextField(
                    key: const Key('network-proxy-port'),
                    controller: portController,
                    enabled: enabled,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => onEndpointChanged(),
                    decoration: _fieldDecoration(context, label: '端口', hint: '9000'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProxyTrafficCard extends StatelessWidget {
  const _ProxyTrafficCard({required this.enabled, required this.saving, required this.onChanged});

  final Map<NetworkProxyTraffic, bool> enabled;
  final bool saving;
  final void Function(NetworkProxyTraffic traffic, bool value) onChanged;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      key: const Key('network-proxy-traffic-card'),
      decoration: _cardDecoration(tokens),
      child: ClipRRect(
        borderRadius: AppRadii.detailCard,
        child: Column(
          children: <Widget>[
            for (final NetworkProxyTraffic traffic in NetworkProxyTraffic.values) ...<Widget>[
              _ProxyTrafficRow(
                traffic: traffic,
                value: enabled[traffic] ?? false,
                enabled: !saving,
                onChanged: (bool value) => onChanged(traffic, value),
              ),
              if (traffic != NetworkProxyTraffic.values.last)
                Padding(
                  padding: const EdgeInsets.only(left: 72),
                  child: Divider(height: 1, color: tokens.divider),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SystemProxyCard extends StatelessWidget {
  const _SystemProxyCard();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      key: const Key('network-proxy-system-card'),
      decoration: _cardDecoration(tokens),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.comfortable, AppSpacing.regular, AppSpacing.compact, AppSpacing.regular),
        child: Row(
          children: <Widget>[
            _ProxyIconBadge(icon: Icons.settings_ethernet_rounded, background: tokens.accentSoft, foreground: tokens.accent, size: 40),
            const SizedBox(width: AppSpacing.comfortable),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('自动使用系统代理', style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    Platform.isWindows ? '读取 HTTP_PROXY、HTTPS_PROXY、NO_PROXY 和 Windows 手动代理；自定义范围可单独覆盖' : '读取当前平台网络代理；自定义范围可单独覆盖',
                    style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.compact),
            Icon(Icons.check_circle_rounded, color: tokens.accent),
          ],
        ),
      ),
    );
  }
}

class _PlayerLocalProxyCard extends StatelessWidget {
  const _PlayerLocalProxyCard({required this.value, required this.enabled, required this.onChanged});

  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      key: const Key('network-proxy-player-local-card'),
      decoration: _cardDecoration(tokens),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.comfortable, AppSpacing.regular, AppSpacing.compact, AppSpacing.regular),
        child: Row(
          children: <Widget>[
            _ProxyIconBadge(icon: Icons.route_rounded, background: tokens.accentSoft, foreground: tokens.accent, size: 40),
            const SizedBox(width: AppSpacing.comfortable),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('强制代理本地 Runtime', style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    Platform.isWindows ? '关闭播放器对 127.0.0.1 的自动绕过；需先启用视频或音频，并使用 HTTP 代理' : '当前仅 Windows MediaKit 播放器支持修改本地地址绕过策略',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: enabled ? tokens.mutedText : tokens.mutedText.withValues(alpha: 0.68),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.compact),
            Switch(key: const Key('network-proxy-force-player-local'), value: value, onChanged: enabled ? onChanged : null),
          ],
        ),
      ),
    );
  }
}

class _ProxyTrafficRow extends StatelessWidget {
  const _ProxyTrafficRow({required this.traffic, required this.value, required this.enabled, required this.onChanged});

  final NetworkProxyTraffic traffic;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      container: true,
      child: Padding(
        key: Key('network-proxy-${traffic.name}'),
        padding: const EdgeInsets.fromLTRB(AppSpacing.comfortable, AppSpacing.regular, AppSpacing.compact, AppSpacing.regular),
        child: Row(
          children: <Widget>[
            _ProxyIconBadge(icon: _icon(traffic), background: tokens.accentSoft, foreground: tokens.accent, size: 40),
            const SizedBox(width: AppSpacing.comfortable),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(_label(traffic), style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    _description(traffic),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: enabled ? tokens.mutedText : tokens.mutedText.withValues(alpha: 0.68),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.compact),
            Switch(value: value, onChanged: enabled ? onChanged : null),
          ],
        ),
      ),
    );
  }
}

class _ProxyNotice extends StatelessWidget {
  const _ProxyNotice({required this.message, this.warning = false, this.noticeKey});

  final String message;
  final bool warning;
  final Key? noticeKey;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final Color foreground = warning ? tokens.warning : tokens.mutedText;
    return DecoratedBox(
      key: noticeKey,
      decoration: BoxDecoration(
        color: warning ? tokens.warning.withValues(alpha: 0.08) : tokens.mutedSurface,
        borderRadius: AppRadii.detailControl,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(warning ? Icons.error_outline_rounded : Icons.lock_outline_rounded, size: 18, color: foreground),
            const SizedBox(width: AppSpacing.compact),
            Expanded(
              child: Text(message, style: theme.textTheme.bodySmall?.copyWith(color: foreground)),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProxySaveBar extends StatelessWidget {
  const _ProxySaveBar({required this.saving, required this.onPressed});

  final bool saving;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.pageBackground,
          border: Border(top: BorderSide(color: tokens.divider)),
          boxShadow: <BoxShadow>[BoxShadow(color: tokens.shadow.withValues(alpha: 0.12), blurRadius: 16, offset: const Offset(0, -4))],
        ),
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(
            AppDetailMetrics.horizontalPadding,
            AppSpacing.regular,
            AppDetailMetrics.horizontalPadding,
            AppSpacing.regular,
          ),
          child: SizedBox(
            height: AppSpacing.minimumTouchTarget,
            child: FilledButton.icon(
              key: const Key('network-proxy-save'),
              onPressed: onPressed,
              icon: saving
                  ? SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.onPrimary))
                  : const Icon(Icons.check_rounded, size: 20),
              label: Text(saving ? '正在保存…' : '保存设置'),
              style: FilledButton.styleFrom(shape: const RoundedRectangleBorder(borderRadius: AppRadii.control)),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProxyIconBadge extends StatelessWidget {
  const _ProxyIconBadge({required this.icon, required this.background, required this.foreground, required this.size});

  final IconData icon;
  final Color background;
  final Color foreground;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: DecoratedBox(
      decoration: BoxDecoration(color: background, borderRadius: AppRadii.detailControl),
      child: Icon(icon, size: size * 0.5, color: foreground),
    ),
  );
}

BoxDecoration _cardDecoration(AppThemeTokens tokens) => BoxDecoration(
  color: tokens.surface,
  borderRadius: AppRadii.detailCard,
  border: Border.all(color: tokens.divider),
  boxShadow: <BoxShadow>[BoxShadow(color: tokens.shadow.withValues(alpha: 0.08), blurRadius: 14, offset: const Offset(0, 4))],
);

InputDecoration _fieldDecoration(BuildContext context, {required String label, String? hint, IconData? icon}) {
  final AppThemeTokens tokens = AppThemeTokens.of(context);
  return InputDecoration(
    labelText: label,
    hintText: hint,
    prefixIcon: icon == null ? null : Icon(icon, size: 20),
    filled: true,
    fillColor: tokens.mutedSurface,
    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.regular, vertical: AppSpacing.comfortable),
    enabledBorder: const OutlineInputBorder(
      borderRadius: AppRadii.detailControl,
      borderSide: BorderSide(color: Colors.transparent),
    ),
    disabledBorder: const OutlineInputBorder(
      borderRadius: AppRadii.detailControl,
      borderSide: BorderSide(color: Colors.transparent),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: AppRadii.detailControl,
      borderSide: BorderSide(color: tokens.accent, width: 1.4),
    ),
  );
}

String _label(NetworkProxyTraffic value) => switch (value) {
  NetworkProxyTraffic.sourceHttp => '数据源 HTTP',
  NetworkProxyTraffic.cover => '封面',
  NetworkProxyTraffic.manga => '漫画',
  NetworkProxyTraffic.video => '视频',
  NetworkProxyTraffic.audio => '音频',
};

String _description(NetworkProxyTraffic value) => switch (value) {
  NetworkProxyTraffic.sourceHttp => '覆盖数据源 ctx.http.fetch 与 Runtime 代取来源资源所用的系统代理',
  NetworkProxyTraffic.cover => '覆盖搜索、发现、详情、书架和播放器网络封面所用的系统代理',
  NetworkProxyTraffic.manga => '覆盖 Flutter 下载漫画图片与相关资源所用的系统代理',
  NetworkProxyTraffic.video => 'MediaKit 播放器访问 Runtime 本地视频清单与分片，仅支持 HTTP 代理',
  NetworkProxyTraffic.audio => 'MediaKit 播放器访问 Runtime 本地音频资源，仅支持 HTTP 代理',
};

IconData _icon(NetworkProxyTraffic value) => switch (value) {
  NetworkProxyTraffic.sourceHttp => Icons.language_rounded,
  NetworkProxyTraffic.cover => Icons.image_outlined,
  NetworkProxyTraffic.manga => Icons.auto_stories_outlined,
  NetworkProxyTraffic.video => Icons.smart_display_outlined,
  NetworkProxyTraffic.audio => Icons.headphones_outlined,
};
