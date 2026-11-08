/// Cinema-styled, bounded TV picker presentation for the video player's modal route.
///
/// Owns layout only: discovery, retries and handoff stay with the caller.
/// Neutral black/gray surfaces and red actions match video chrome.
/// The whole sheet scrolls on short screens and respects the bottom safe area.
library;

import 'package:flutter/material.dart';

import '../domain/companion_models.dart';

const _accent = Color(0xFFE50914);
const _foreground = Color(0xFFF5F5F5);
const _secondary = Color(0xFFB3B3B3);
const _card = Color(0xFF262626);

/// Device selection and discovery states, independent of transport lifetime.
final class VideoTvPickerSheet extends StatelessWidget {
  const VideoTvPickerSheet({
    super.key,
    required this.loading,
    required this.endpoints,
    required this.onSelect,
    required this.onManual,
    required this.onRetry,
    required this.onClose,
    this.error,
  });

  static const backgroundColor = Color(0xFF181818);

  /// Shared with the modal route so nested manual connection dialogs inherit it.
  static ThemeData themeFor(ThemeData base) => base.copyWith(
    colorScheme: const ColorScheme.dark(primary: _accent, onPrimary: Colors.white, surface: backgroundColor, onSurface: _foreground),
    textTheme: base.textTheme.apply(bodyColor: _foreground, displayColor: _foreground),
    dialogTheme: const DialogThemeData(backgroundColor: backgroundColor, surfaceTintColor: Colors.transparent),
  );

  final bool loading;
  final List<CompanionEndpoint> endpoints;
  final String? error;
  final ValueChanged<CompanionEndpoint> onSelect;
  final VoidCallback onManual;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    return Theme(
      data: themeFor(base),
      child: Material(
        color: backgroundColor,
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .82),
            child: SingleChildScrollView(
              key: const Key('companion-cast-scroll'),
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 32,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(color: const Color(0xFF707070), borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  Row(
                    children: [
                      const _IconTile(icon: Icons.cast_rounded, accented: true),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('在电视上播放', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, height: 1.3)),
                            SizedBox(height: 4),
                            Text('选择同一局域网内的电视', style: TextStyle(fontSize: 12, color: _secondary)),
                          ],
                        ),
                      ),
                      IconButton(
                        key: const Key('companion-cast-close'),
                        tooltip: '关闭',
                        onPressed: onClose,
                        style: IconButton.styleFrom(foregroundColor: _secondary, visualDensity: VisualDensity.compact),
                        icon: const Icon(Icons.close_rounded, size: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  if (endpoints.isEmpty)
                    _DiscoveryState(loading: loading, error: error)
                  else ...[
                    const Padding(
                      padding: EdgeInsets.only(bottom: 10),
                      child: Text('可用设备', style: TextStyle(color: _secondary, fontSize: 12)),
                    ),
                    for (final endpoint in endpoints)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _ActionCard(
                          key: Key('companion-cast-device-${endpoint.deviceId}'),
                          icon: Icons.tv_rounded,
                          title: endpoint.label,
                          subtitle: '${endpoint.address}:${endpoint.port}',
                          trailing: Icons.play_arrow_rounded,
                          accented: true,
                          onTap: () => onSelect(endpoint),
                        ),
                      ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 12),
                        child: Text(error!, style: const TextStyle(fontSize: 12, color: _secondary)),
                      ),
                  ],
                  const SizedBox(height: 16),
                  _ActionCard(
                    key: const Key('companion-cast-manual'),
                    icon: Icons.keyboard_rounded,
                    title: '手动连接',
                    subtitle: '输入电视的 IP 地址和端口',
                    trailing: Icons.chevron_right_rounded,
                    onTap: onManual,
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      key: const Key('companion-cast-retry'),
                      onPressed: loading ? null : onRetry,
                      icon: Icon(loading ? Icons.wifi_find_rounded : Icons.refresh_rounded, size: 18),
                      label: Text(loading ? '正在搜索电视…' : '重新搜索'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFE50914),
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: _card,
                        disabledForegroundColor: _secondary,
                        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Text(
                      '电视开始播放后，手机会自动暂停',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: _secondary, height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _DiscoveryState extends StatelessWidget {
  const _DiscoveryState({required this.loading, this.error});

  final bool loading;
  final String? error;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: const Color(0xFF222222),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFF333333)),
    ),
    child: Row(
      children: [
        if (loading)
          const Padding(
            padding: EdgeInsets.all(12),
            child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2, color: _accent)),
          )
        else
          _IconTile(icon: error == null ? Icons.tv_rounded : Icons.wifi_off_rounded),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                loading ? '正在寻找附近的电视' : (error == null ? '还没有发现电视' : '暂时无法搜索'),
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 6),
              Text(error ?? '请打开电视上的 MgRead\n确认两台设备在同一局域网', style: const TextStyle(fontSize: 12, height: 1.6, color: _secondary)),
            ],
          ),
        ),
      ],
    ),
  );
}

final class _ActionCard extends StatelessWidget {
  const _ActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.onTap,
    this.accented = false,
  });

  final IconData icon, trailing;
  final String title, subtitle;
  final VoidCallback onTap;
  final bool accented;

  @override
  Widget build(BuildContext context) => Material(
    color: _card,
    borderRadius: BorderRadius.circular(8),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            _IconTile(icon: icon, accented: accented),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 4),
                  Text(subtitle, style: const TextStyle(fontSize: 11, color: _secondary, height: 1.4)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(trailing, size: 20, color: accented ? _accent : _secondary),
          ],
        ),
      ),
    ),
  );
}

final class _IconTile extends StatelessWidget {
  const _IconTile({required this.icon, this.accented = false});

  final IconData icon;
  final bool accented;

  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    height: 44,
    decoration: BoxDecoration(color: accented ? const Color(0xFFE50914) : const Color(0xFF303030), borderRadius: BorderRadius.circular(8)),
    child: Icon(icon, size: 23, color: accented ? Colors.white : _secondary),
  );
}
