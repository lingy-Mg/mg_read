import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

/// Reference-matched data-source management presentation.
///
/// Runtime-side installation, import, and enable writes are intentionally not
/// inferred here. This surface is the fixed management composition requested
/// for the current product UI and only exposes a local unavailable notice for
/// the future add action.
class PluginRuntimeStatusPage extends StatelessWidget {
  const PluginRuntimeStatusPage({
    required this.onBackRequested,
    required this.onDestinationRequested,
    super.key,
  });

  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;

  @override
  Widget build(BuildContext context) {
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
              const Expanded(child: _DataSourceContent()),
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
        content: const Text('在这里查看和管理已添加的数据来源。'),
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

class _DataSourceContent extends StatelessWidget {
  const _DataSourceContent();

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
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
                const _DataSourceSectionHeader(),
                const SizedBox(height: AppSpacing.compact),
                ...List<Widget>.generate(_referenceSources.length, (int index) {
                  final _DataSourceViewData source = _referenceSources[index];
                  return Column(
                    children: <Widget>[
                      _DataSourceRow(source: source),
                      if (index < _referenceSources.length - 1)
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
                _AddDataSourceButton(
                  onPressed: () => _showAddUnavailableMessage(context),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _DataSourceSectionHeader extends StatelessWidget {
  const _DataSourceSectionHeader();

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
          '已启用 6/12',
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

class _DataSourceRow extends StatelessWidget {
  const _DataSourceRow({required this.source});

  final _DataSourceViewData source;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      label:
          '${source.name}，小说，${source.origin}，${source.enabled ? '已启用' : '未启用'}',
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
                    '小说 · ${source.origin}',
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
              child: IgnorePointer(
                child: Transform.scale(
                  scale: 0.70,
                  child: Switch(
                    key: ValueKey<String>('data-source-toggle-${source.id}'),
                    value: source.enabled,
                    onChanged: (_) {},
                    activeTrackColor: tokens.dataSourceAccent,
                    activeThumbColor: theme.colorScheme.onPrimary,
                    inactiveTrackColor: tokens.mutedSurface,
                    inactiveThumbColor: tokens.surface,
                    trackOutlineColor:
                        const WidgetStatePropertyAll<Color>(Colors.transparent),
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
    final Color foreground = brand == _DataSourceBrand.qimao
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onPrimary;
    final _BrandColors colors = switch (brand) {
      _DataSourceBrand.qidian => _BrandColors(tokens.notification, foreground),
      _DataSourceBrand.tomato => _BrandColors(
        tokens.dataSourceAccent,
        foreground,
      ),
      _DataSourceBrand.qimao => _BrandColors(
        tokens.dataSourceCat,
        foreground,
      ),
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

    final Path fruit = Path()
      ..moveTo(6 * unit, 21 * unit)
      ..quadraticBezierTo(18 * unit, 8 * unit, 30 * unit, 21 * unit)
      ..lineTo(30 * unit, 26 * unit)
      ..quadraticBezierTo(18 * unit, 35 * unit, 6 * unit, 26 * unit)
      ..close();
    canvas.drawPath(fruit, paint);

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
  const _AddDataSourceButton({required this.onPressed});

  final VoidCallback onPressed;

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
          onTap: onPressed,
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
    required this.origin,
    required this.enabled,
    required this.brand,
  });

  final String id;
  final String name;
  final String origin;
  final bool enabled;
  final _DataSourceBrand brand;
}

class _BrandColors {
  const _BrandColors(this.background, this.foreground);

  final Color background;
  final Color foreground;
}

enum _DataSourceBrand { qidian, tomato, qimao, zongheng, jinjiang, seventeenK }

const List<_DataSourceViewData> _referenceSources = <_DataSourceViewData>[
  _DataSourceViewData(
    id: 'qidian',
    name: '起点中文网',
    origin: '官方源',
    enabled: true,
    brand: _DataSourceBrand.qidian,
  ),
  _DataSourceViewData(
    id: 'tomato',
    name: '番茄小说',
    origin: '官方源',
    enabled: true,
    brand: _DataSourceBrand.tomato,
  ),
  _DataSourceViewData(
    id: 'qimao',
    name: '七猫中文网',
    origin: '官方源',
    enabled: true,
    brand: _DataSourceBrand.qimao,
  ),
  _DataSourceViewData(
    id: 'zongheng',
    name: '纵横中文网',
    origin: '官方源',
    enabled: true,
    brand: _DataSourceBrand.zongheng,
  ),
  _DataSourceViewData(
    id: 'jinjiang',
    name: '晋江文学城',
    origin: '社区源',
    enabled: false,
    brand: _DataSourceBrand.jinjiang,
  ),
  _DataSourceViewData(
    id: '17k',
    name: '17K小说网',
    origin: '社区源',
    enabled: false,
    brand: _DataSourceBrand.seventeenK,
  ),
];

void _showAddUnavailableMessage(BuildContext context) {
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(const SnackBar(content: Text('添加数据来源将在导入能力接入后开放。')));
}
