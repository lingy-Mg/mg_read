/// 数据源管理列表行与品牌标记。
///
/// 职责：
/// - 渲染数据源的品牌图标、开发源角标和启停控件。
/// - 将开发源与已安装源的视觉状态保持一致且可访问。
///
/// 注意：
/// - 仅接收不可变展示数据，不发起 Runtime 或磁盘操作。
/// - 开发源不允许在此处切换启停状态。
///
/// TODO:
/// - 无。
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/source_branding.dart';

enum DataSourceBrand { qidian, tomato, qimao, zongheng, jinjiang, seventeenK, generic }

final class DataSourceManagementRowData {
  const DataSourceManagementRowData({
    required this.id,
    required this.name,
    required this.description,
    required this.kindLabel,
    required this.enabled,
    required this.brand,
    required this.isDevelopment,
    this.iconUrl,
  });

  final String id;
  final String name;
  final String description;
  final String kindLabel;
  final bool enabled;
  final DataSourceBrand brand;
  final bool isDevelopment;
  final String? iconUrl;
}

class DataSourceManagementRow extends StatelessWidget {
  const DataSourceManagementRow({
    required this.source,
    required this.isPending,
    required this.onPressed,
    required this.onChanged,
    super.key,
  });

  final DataSourceManagementRowData source;
  final bool isPending;
  final VoidCallback onPressed;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      label: '${source.name}，${source.kindLabel}，${source.enabled ? '已启用' : '未启用'}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey<String>('data-source-${source.id}'),
          onTap: onPressed,
          borderRadius: AppRadii.discoveryTile,
          child: SizedBox(
            height: AppSpacing.dataSourceRowHeight + AppSpacing.compact,
            child: Row(
              children: <Widget>[
                _DataSourceBrandMark(
                  sourceId: source.id,
                  displayName: source.name,
                  brand: source.brand,
                  isDevelopment: source.isDevelopment,
                  iconUrl: source.iconUrl,
                ),
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
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.12),
                      ),
                      const SizedBox(height: AppSpacing.unit),
                      Text(
                        source.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText, height: 1.1),
                      ),
                      const SizedBox(height: AppSpacing.unit),
                      Text(
                        source.kindLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText, height: 1.1),
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
                      onChanged: isPending || source.isDevelopment ? null : onChanged,
                      activeTrackColor: tokens.dataSourceAccent,
                      activeThumbColor: theme.colorScheme.onPrimary,
                      inactiveTrackColor: tokens.mutedSurface,
                      inactiveThumbColor: tokens.surface,
                      trackOutlineColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

DataSourceBrand dataSourceBrandFor(String displayName) {
  return switch (displayName) {
    '起点中文网' => DataSourceBrand.qidian,
    '番茄小说' => DataSourceBrand.tomato,
    '七猫中文网' => DataSourceBrand.qimao,
    '纵横中文网' => DataSourceBrand.zongheng,
    '晋江文学城' => DataSourceBrand.jinjiang,
    '17K小说网' || '17K 小说网' => DataSourceBrand.seventeenK,
    _ => DataSourceBrand.generic,
  };
}

class _DataSourceBrandMark extends StatelessWidget {
  const _DataSourceBrandMark({
    required this.sourceId,
    required this.displayName,
    required this.brand,
    required this.isDevelopment,
    required this.iconUrl,
  });

  final String sourceId;
  final String displayName;
  final DataSourceBrand brand;
  final bool isDevelopment;
  final String? iconUrl;

  @override
  Widget build(BuildContext context) {
    final Widget fallback = SourceBranding.assetFor(sourceId) != null
        ? SourceIcon(sourceId: sourceId, displayName: displayName, size: AppSpacing.dataSourceMarkExtent, borderRadius: 12)
        : _GeneratedBrandMark(brand: brand);
    final Uri? iconUri = Uri.tryParse(iconUrl ?? '');
    final Widget mark = iconUri != null && (iconUri.scheme == 'http' || iconUri.scheme == 'https')
        ? ClipRRect(
            borderRadius: AppRadii.discoveryTile,
            child: Image.network(
              iconUri.toString(),
              width: AppSpacing.dataSourceMarkExtent,
              height: AppSpacing.dataSourceMarkExtent,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            ),
          )
        : fallback;
    if (!isDevelopment) return mark;
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final ThemeData theme = Theme.of(context);
    return Semantics(
      label: '开发源',
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          mark,
          Positioned(
            right: -AppSpacing.unit,
            bottom: -AppSpacing.unit,
            child: DecoratedBox(
              key: ValueKey<String>('data-source-development-badge-$sourceId'),
              decoration: BoxDecoration(
                color: tokens.dataSourceAccent,
                shape: BoxShape.circle,
                border: Border.all(color: theme.colorScheme.surface, width: 2),
              ),
              child: const SizedBox(
                width: AppSpacing.regular,
                height: AppSpacing.regular,
                child: Icon(Icons.code_rounded, size: AppSpacing.compact, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GeneratedBrandMark extends StatelessWidget {
  const _GeneratedBrandMark({required this.brand});

  final DataSourceBrand brand;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final Color foreground = switch (brand) {
      DataSourceBrand.qimao => theme.colorScheme.onSurface,
      DataSourceBrand.generic => tokens.dataSourceAccent,
      _ => theme.colorScheme.onPrimary,
    };
    final _BrandColors colors = switch (brand) {
      DataSourceBrand.qidian => _BrandColors(tokens.notification, foreground),
      DataSourceBrand.tomato => _BrandColors(tokens.dataSourceAccent, foreground),
      DataSourceBrand.qimao => _BrandColors(tokens.dataSourceCat, foreground),
      DataSourceBrand.zongheng => _BrandColors(tokens.notification, foreground),
      DataSourceBrand.jinjiang => _BrandColors(tokens.dataSourceCommunity, foreground),
      DataSourceBrand.seventeenK => _BrandColors(tokens.dataSourceAccent, foreground),
      DataSourceBrand.generic => _BrandColors(tokens.accentSoft, foreground),
    };
    return DecoratedBox(
      decoration: BoxDecoration(color: colors.background, borderRadius: AppRadii.discoveryTile),
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

  final DataSourceBrand brand;
  final Color color;

  @override
  Widget build(BuildContext context) => switch (brand) {
    DataSourceBrand.qidian => Text('起', style: _glyphTextStyle(context, color)),
    DataSourceBrand.tomato => CustomPaint(size: const Size.square(AppSpacing.dataSourceMarkExtent), painter: _TomatoMarkPainter(color)),
    DataSourceBrand.qimao => CustomPaint(size: const Size.square(AppSpacing.dataSourceMarkExtent), painter: _CatMarkPainter(color)),
    DataSourceBrand.zongheng => _GridBrandGlyph(color: color),
    DataSourceBrand.jinjiang => CustomPaint(size: const Size.square(AppSpacing.dataSourceMarkExtent), painter: _JinjiangMarkPainter(color)),
    DataSourceBrand.seventeenK => Text('17K', style: _glyphTextStyle(context, color)),
    DataSourceBrand.generic => Icon(Icons.extension_rounded, color: color, size: AppSpacing.dataSourceAddIconSize),
  };

  TextStyle? _glyphTextStyle(BuildContext context, Color foreground) =>
      Theme.of(context).textTheme.titleLarge?.copyWith(color: foreground, fontWeight: FontWeight.w700, height: 1, letterSpacing: -0.8);
}

class _GridBrandGlyph extends StatelessWidget {
  const _GridBrandGlyph({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
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
  bool shouldRepaint(covariant _TomatoMarkPainter oldDelegate) => oldDelegate.color != color;
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
    canvas.drawOval(Rect.fromCenter(center: Offset(15 * unit, 17 * unit), width: 5 * unit, height: 3 * unit), eyePaint);
    canvas.drawOval(Rect.fromCenter(center: Offset(23 * unit, 17 * unit), width: 5 * unit, height: 3 * unit), eyePaint);
    canvas.drawCircle(Offset(16 * unit, 17 * unit), unit, paint);
    canvas.drawCircle(Offset(22 * unit, 17 * unit), unit, paint);
  }

  @override
  bool shouldRepaint(covariant _CatMarkPainter oldDelegate) => oldDelegate.color != color;
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
    canvas.drawLine(Offset(11 * unit, 28 * unit), Offset(20 * unit, 16 * unit), paint);
  }

  @override
  bool shouldRepaint(covariant _JinjiangMarkPainter oldDelegate) => oldDelegate.color != color;
}

class _BrandColors {
  const _BrandColors(this.background, this.foreground);

  final Color background;
  final Color foreground;
}
