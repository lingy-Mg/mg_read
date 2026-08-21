import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

/// Runtime-backed data-source management presentation.
class PluginRuntimeStatusPage extends ConsumerWidget {
  const PluginRuntimeStatusPage({
    required this.onBackRequested,
    required this.onDestinationRequested,
    super.key,
  });

  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<PluginRuntimeConnection> connection = ref.watch(
      pluginRuntimeConnectionProvider,
    );
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppDetailMetrics.viewportWidth,
          ),
          child: Column(
            children: <Widget>[
              _DataSourceTopBar(
                onBack: onBackRequested,
                onHelp: () => _showHelp(context),
              ),
              Expanded(
                child: connection.when(
                  loading: () => const _DataSourceLoading(),
                  error: (Object _, StackTrace _) => _DataSourceFailure(
                    onRetry: () =>
                        ref.invalidate(pluginRuntimeConnectionProvider),
                  ),
                  data: (PluginRuntimeConnection value) => _DataSourceContent(
                    sources: _sourcesFromConnection(value),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showHelp(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('数据来源说明'),
        content: const Text('在这里查看已添加的数据来源，并直接启用或停用它们。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

class _DataSourceTopBar extends StatelessWidget {
  const _DataSourceTopBar({required this.onBack, required this.onHelp});

  final VoidCallback onBack;
  final VoidCallback onHelp;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      key: const Key('data-source-top-bar'),
      width: double.infinity,
      height: AppSpacing.dataSourceTopBarHeight,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Semantics(
            header: true,
            child: Text(
              '管理数据来源',
              style: theme.textTheme.titleLarge?.copyWith(
                fontSize: AppSpacing.dataSourcePageTitleSize,
                fontWeight: FontWeight.w700,
                height: 1.15,
                letterSpacing: -0.45,
              ),
            ),
          ),
          Positioned(
            left: AppSpacing.unit,
            top:
                (AppSpacing.dataSourceTopBarHeight -
                    AppSpacing.minimumTouchTarget) /
                2,
            child: _HeaderButton(
              key: const Key('profile-detail-back'),
              label: '返回',
              icon: Icons.arrow_back,
              onPressed: onBack,
            ),
          ),
          Positioned(
            right: AppSpacing.unit,
            top:
                (AppSpacing.dataSourceTopBarHeight -
                    AppSpacing.minimumTouchTarget) /
                2,
            child: _HeaderButton(
              key: const Key('data-source-management-help'),
              label: '数据来源说明',
              icon: Icons.help_outline,
              onPressed: onHelp,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: IconButton(
          onPressed: onPressed,
          icon: Icon(icon),
          iconSize: AppSpacing.dataSourceHeaderIconSize,
          color: theme.colorScheme.onSurface,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(
            width: AppSpacing.minimumTouchTarget,
            height: AppSpacing.minimumTouchTarget,
          ),
        ),
      ),
    );
  }
}

class _DataSourceLoading extends StatelessWidget {
  const _DataSourceLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(
        key: Key('data-source-management-loading'),
      ),
    );
  }
}

class _DataSourceFailure extends StatelessWidget {
  const _DataSourceFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TextButton(
        key: const Key('data-source-management-retry'),
        onPressed: onRetry,
        child: const Text('数据来源暂不可用，点击重试'),
      ),
    );
  }
}

class _DataSourceContent extends ConsumerStatefulWidget {
  const _DataSourceContent({required this.sources});

  final List<_DataSourceViewData> sources;

  @override
  ConsumerState<_DataSourceContent> createState() => _DataSourceContentState();
}

class _DataSourceContentState extends ConsumerState<_DataSourceContent> {
  Future<void> _setSourceEnabled(
    _DataSourceViewData source,
    bool enabled,
  ) async {
    try {
      await ref
          .read(pluginRuntimeSourceActionProvider.notifier)
          .setEnabled(pluginId: source.id, enabled: enabled);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('数据来源状态更新失败，请稍后重试。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final Set<String> pendingSourceIds = ref.watch(
      pluginRuntimeSourceActionProvider,
    );
    final int enabledCount = widget.sources
        .where((_DataSourceViewData source) => source.enabled)
        .length;
    return ListView(
      key: const Key('data-source-management-content'),
      padding: const EdgeInsets.fromLTRB(
        AppDetailMetrics.horizontalPadding,
        AppSpacing.regular,
        AppDetailMetrics.horizontalPadding,
        AppSpacing.comfortable,
      ),
      children: <Widget>[
        DecoratedBox(
          key: const Key('data-source-management-card'),
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: AppRadii.profileList,
            border: Border.all(color: tokens.divider),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: tokens.shadow.withValues(alpha: 0.16),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.comfortable,
              AppSpacing.comfortable + AppSpacing.compact,
              AppSpacing.comfortable,
              AppSpacing.regular,
            ),
            child: Column(
              children: <Widget>[
                _DataSourceSectionHeader(
                  enabledCount: enabledCount,
                  sourceCount: widget.sources.length,
                ),
                const SizedBox(height: AppSpacing.compact),
                if (widget.sources.isEmpty)
                  const _DataSourceEmptyState()
                else
                  ...List<Widget>.generate(widget.sources.length, (int index) {
                    final _DataSourceViewData source = widget.sources[index];
                    return Column(
                      children: <Widget>[
                        _DataSourceRow(
                          source: source,
                          isPending: pendingSourceIds.contains(source.id),
                          onChanged: (bool enabled) =>
                              _setSourceEnabled(source, enabled),
                        ),
                        if (index < widget.sources.length - 1)
                          Padding(
                            padding: const EdgeInsets.only(
                              left:
                                  AppSpacing.dataSourceMarkExtent +
                                  AppSpacing.regular,
                            ),
                            child: Divider(height: 1, color: tokens.divider),
                          ),
                      ],
                    );
                  }),
                const SizedBox(height: AppSpacing.comfortable),
                const _AddDataSourceButton(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _DataSourceSectionHeader extends StatelessWidget {
  const _DataSourceSectionHeader({
    required this.enabledCount,
    required this.sourceCount,
  });

  final int enabledCount;
  final int sourceCount;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            '我的数据来源',
            style: theme.textTheme.titleLarge?.copyWith(
              fontSize: AppSpacing.dataSourceSectionTitleSize,
              fontWeight: FontWeight.w700,
              height: 1.2,
              letterSpacing: -0.3,
            ),
          ),
        ),
        Text(
          '已启用 $enabledCount/$sourceCount',
          key: const Key('data-source-enabled-count'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: tokens.mutedText,
            fontSize: AppSpacing.dataSourceMetadataSize,
          ),
        ),
      ],
    );
  }
}

class _DataSourceEmptyState extends StatelessWidget {
  const _DataSourceEmptyState();

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      height: AppSpacing.dataSourceRowHeight,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '暂无已安装的数据来源',
          key: const Key('data-source-management-empty'),
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
        ),
      ),
    );
  }
}

class _DataSourceRow extends StatelessWidget {
  const _DataSourceRow({
    required this.source,
    required this.isPending,
    required this.onChanged,
  });

  final _DataSourceViewData source;
  final bool isPending;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      label:
          '${source.name}，${source.kindLabel}，${source.enabled ? '已启用' : '未启用'}',
      child: SizedBox(
        key: ValueKey<String>('data-source-${source.id}'),
        height: AppSpacing.dataSourceRowHeight,
        child: Row(
          children: <Widget>[
            _DataSourceBrandMark(brand: source.brand),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    source.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontSize: AppSpacing.dataSourceNameSize,
                      fontWeight: FontWeight.w600,
                      height: 1.12,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.unit),
                  Text(
                    source.kindLabel,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: tokens.mutedText,
                      fontSize: AppSpacing.dataSourceMetadataSize,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: AppSpacing.minimumTouchTarget,
              height: AppSpacing.minimumTouchTarget,
              child: Transform.scale(
                scale: 0.70,
                child: Switch(
                  key: ValueKey<String>('data-source-toggle-${source.id}'),
                  value: source.enabled,
                  onChanged: isPending ? null : onChanged,
                  activeTrackColor: tokens.dataSourceAccent,
                  activeThumbColor: theme.colorScheme.onPrimary,
                  inactiveTrackColor: tokens.mutedSurface,
                  inactiveThumbColor: tokens.surface,
                  trackOutlineColor: const WidgetStatePropertyAll<Color>(
                    Colors.transparent,
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

class _DataSourceBrandMark extends StatelessWidget {
  const _DataSourceBrandMark({required this.brand});

  final _DataSourceBrand brand;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final Color foreground = switch (brand) {
      _DataSourceBrand.qimao => theme.colorScheme.onSurface,
      _DataSourceBrand.generic => tokens.dataSourceAccent,
      _ => theme.colorScheme.onPrimary,
    };
    final _BrandColors colors = switch (brand) {
      _DataSourceBrand.qidian => _BrandColors(tokens.notification, foreground),
      _DataSourceBrand.tomato => _BrandColors(
        tokens.dataSourceAccent,
        foreground,
      ),
      _DataSourceBrand.qimao => _BrandColors(tokens.dataSourceCat, foreground),
      _DataSourceBrand.zongheng => _BrandColors(
        tokens.notification,
        foreground,
      ),
      _DataSourceBrand.jinjiang => _BrandColors(
        tokens.dataSourceCommunity,
        foreground,
      ),
      _DataSourceBrand.seventeenK => _BrandColors(
        tokens.dataSourceAccent,
        foreground,
      ),
      _DataSourceBrand.generic => _BrandColors(tokens.accentSoft, foreground),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: AppRadii.discoveryTile,
      ),
      child: SizedBox(
        width: AppSpacing.dataSourceMarkExtent,
        height: AppSpacing.dataSourceMarkExtent,
        child: Center(
          child: _BrandGlyph(brand: brand, color: colors.foreground),
        ),
      ),
    );
  }
}

class _BrandGlyph extends StatelessWidget {
  const _BrandGlyph({required this.brand, required this.color});

  final _DataSourceBrand brand;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return switch (brand) {
      _DataSourceBrand.qidian => Text(
        '起',
        style: _glyphTextStyle(context, color, 25),
      ),
      _DataSourceBrand.tomato => CustomPaint(
        size: const Size.square(AppSpacing.dataSourceMarkExtent),
        painter: _TomatoMarkPainter(color),
      ),
      _DataSourceBrand.qimao => CustomPaint(
        size: const Size.square(AppSpacing.dataSourceMarkExtent),
        painter: _CatMarkPainter(color),
      ),
      _DataSourceBrand.zongheng => _GridBrandGlyph(color: color),
      _DataSourceBrand.jinjiang => CustomPaint(
        size: const Size.square(AppSpacing.dataSourceMarkExtent),
        painter: _JinjiangMarkPainter(color),
      ),
      _DataSourceBrand.seventeenK => Text(
        '17K',
        style: _glyphTextStyle(context, color, 15),
      ),
      _DataSourceBrand.generic => Icon(
        Icons.extension_rounded,
        color: color,
        size: AppSpacing.dataSourceAddIconSize,
      ),
    };
  }

  TextStyle? _glyphTextStyle(
    BuildContext context,
    Color foreground,
    double size,
  ) {
    return Theme.of(context).textTheme.titleLarge?.copyWith(
      color: foreground,
      fontSize: size,
      fontWeight: FontWeight.w700,
      height: 1,
      letterSpacing: -0.8,
    );
  }
}

class _GridBrandGlyph extends StatelessWidget {
  const _GridBrandGlyph({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: AppSpacing.dataSourceMarkExtent - AppSpacing.regular,
      height: AppSpacing.dataSourceMarkExtent - AppSpacing.regular,
      child: Wrap(
        spacing: AppSpacing.unit,
        runSpacing: AppSpacing.unit,
        children: List<Widget>.generate(
          9,
          (_) => SizedBox(
            width: AppSpacing.unit * 2,
            height: AppSpacing.unit * 2,
            child: DecoratedBox(decoration: BoxDecoration(color: color)),
          ),
        ),
      ),
    );
  }
}

class _TomatoMarkPainter extends CustomPainter {
  const _TomatoMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()..color = color;
    final double unit = size.width / AppSpacing.dataSourceMarkExtent;
    final Path stem = Path()
      ..moveTo(20 * unit, 0)
      ..lineTo(27 * unit, 0)
      ..lineTo(29 * unit, 10 * unit)
      ..lineTo(22 * unit, 8 * unit)
      ..close();
    canvas.drawPath(stem, paint);

    for (final Offset center in <Offset>[
      Offset(12 * unit, 23 * unit),
      Offset(18 * unit, 19 * unit),
      Offset(24 * unit, 23 * unit),
      Offset(18 * unit, 27 * unit),
    ]) {
      canvas.drawCircle(center, 1.7 * unit, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TomatoMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _CatMarkPainter extends CustomPainter {
  const _CatMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double unit = size.width / AppSpacing.dataSourceMarkExtent;
    final Paint paint = Paint()..color = color;
    final Path cat = Path()
      ..moveTo(8 * unit, 29 * unit)
      ..lineTo(8 * unit, 14 * unit)
      ..lineTo(13 * unit, 8 * unit)
      ..lineTo(16 * unit, 11 * unit)
      ..lineTo(24 * unit, 11 * unit)
      ..lineTo(28 * unit, 7 * unit)
      ..lineTo(29 * unit, 17 * unit)
      ..quadraticBezierTo(28 * unit, 25 * unit, 23 * unit, 27 * unit)
      ..lineTo(25 * unit, 31 * unit)
      ..lineTo(25 * unit, 34 * unit)
      ..lineTo(10 * unit, 34 * unit)
      ..lineTo(10 * unit, 29 * unit)
      ..close();
    canvas.drawPath(cat, paint);

    final Paint eyePaint = Paint()..color = Colors.white;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(15 * unit, 17 * unit),
        width: 5 * unit,
        height: 3 * unit,
      ),
      eyePaint,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(23 * unit, 17 * unit),
        width: 5 * unit,
        height: 3 * unit,
      ),
      eyePaint,
    );
    canvas.drawCircle(Offset(16 * unit, 17 * unit), unit, paint);
    canvas.drawCircle(Offset(22 * unit, 17 * unit), unit, paint);
  }

  @override
  bool shouldRepaint(covariant _CatMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _JinjiangMarkPainter extends CustomPainter {
  const _JinjiangMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width / 11
      ..strokeCap = StrokeCap.round;
    final double unit = size.width / AppSpacing.dataSourceMarkExtent;
    final Path leaf = Path()
      ..moveTo(7 * unit, 29 * unit)
      ..quadraticBezierTo(10 * unit, 12 * unit, 11 * unit, 6 * unit)
      ..quadraticBezierTo(18 * unit, 13 * unit, 19 * unit, 24 * unit)
      ..quadraticBezierTo(25 * unit, 18 * unit, 29 * unit, 10 * unit)
      ..quadraticBezierTo(28 * unit, 25 * unit, 18 * unit, 31 * unit)
      ..quadraticBezierTo(11 * unit, 33 * unit, 7 * unit, 29 * unit);
    canvas.drawPath(leaf, paint);
    canvas.drawLine(
      Offset(11 * unit, 28 * unit),
      Offset(20 * unit, 16 * unit),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _JinjiangMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _AddDataSourceButton extends StatelessWidget {
  const _AddDataSourceButton();

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      button: true,
      label: '添加数据来源',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('data-source-add'),
          onTap: null,
          borderRadius: AppRadii.discoveryTile,
          child: SizedBox(
            width: double.infinity,
            child: Ink(
              height: AppSpacing.dataSourceAddButtonHeight,
              decoration: BoxDecoration(
                borderRadius: AppRadii.discoveryTile,
                border: Border.all(color: tokens.accentSoft),
                color: tokens.pageBackground,
              ),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.add_rounded,
                      color: tokens.dataSourceAccent,
                      size: AppSpacing.dataSourceAddIconSize,
                    ),
                    const SizedBox(width: AppSpacing.compact),
                    Text(
                      '添加数据来源',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: tokens.dataSourceAccent,
                        fontSize: AppSpacing.dataSourceNameSize,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DataSourceViewData {
  const _DataSourceViewData({
    required this.id,
    required this.name,
    required this.kindLabel,
    required this.enabled,
    required this.brand,
  });

  final String id;
  final String name;
  final String kindLabel;
  final bool enabled;
  final _DataSourceBrand brand;
}

class _BrandColors {
  const _BrandColors(this.background, this.foreground);

  final Color background;
  final Color foreground;
}

enum _DataSourceBrand {
  qidian,
  tomato,
  qimao,
  zongheng,
  jinjiang,
  seventeenK,
  generic,
}

List<_DataSourceViewData> _sourcesFromConnection(
  PluginRuntimeConnection connection,
) {
  return connection.plugins
      .where(
        (PluginRuntimePlugin plugin) =>
            plugin.contentKinds.contains('novel') ||
            plugin.contentKinds.contains('manga'),
      )
      .map(
        (PluginRuntimePlugin plugin) => _DataSourceViewData(
          id: plugin.id,
          name: plugin.displayName,
          kindLabel: _sourceMetadataLabel(plugin),
          enabled: plugin.enabled,
          brand: _brandForPlugin(plugin),
        ),
      )
      .toList(growable: false);
}

String _contentKindLabel(List<String> contentKinds) {
  final List<String> labels = <String>[
    if (contentKinds.contains('novel')) '小说',
    if (contentKinds.contains('manga')) '漫画',
  ];
  return labels.isEmpty ? '数据源' : labels.join(' · ');
}

String _sourceMetadataLabel(PluginRuntimePlugin plugin) {
  final String kindLabel = _contentKindLabel(plugin.contentKinds);
  final String? origin = switch (plugin.displayName) {
    '起点中文网' || '番茄小说' || '七猫中文网' || '纵横中文网' => '官方源',
    '晋江文学城' || '17K小说网' || '17K 小说网' => '社区源',
    _ => null,
  };
  return origin == null ? kindLabel : '$kindLabel · $origin';
}

_DataSourceBrand _brandForPlugin(PluginRuntimePlugin plugin) {
  return switch (plugin.displayName) {
    '起点中文网' => _DataSourceBrand.qidian,
    '番茄小说' => _DataSourceBrand.tomato,
    '七猫中文网' => _DataSourceBrand.qimao,
    '纵横中文网' => _DataSourceBrand.zongheng,
    '晋江文学城' => _DataSourceBrand.jinjiang,
    '17K小说网' || '17K 小说网' => _DataSourceBrand.seventeenK,
    _ => _DataSourceBrand.generic,
  };
}
