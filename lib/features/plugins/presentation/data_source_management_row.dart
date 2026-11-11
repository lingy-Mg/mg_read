/// 数据源管理列表行与品牌标记。
///
/// 职责：
/// - 点击条目打开详情，右侧开关直接启停；内容浏览收纳为独立的次级操作。
/// - 将开发数据源插件与已安装数据源插件的视觉状态保持一致且可访问。
///
/// 注意：
/// - 仅接收不可变展示数据，不发起 Runtime 或磁盘操作。
/// - 开发数据源插件不允许在此处切换启停状态。
///
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/source_branding.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'data_source_management_tv_row.dart';

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
    this.contentKinds = const <String>[],
    this.r18 = false,
    this.canOpen = true,
    this.sourceUrl,
    this.version,
    this.pendingVersion,
    this.availabilityLabel,
    this.unavailableReason,
  });

  final String id;
  final String name;
  final String description;
  final String kindLabel;
  final bool enabled;
  final DataSourceBrand brand;
  final bool isDevelopment;
  final String? iconUrl;
  final List<String> contentKinds;
  final bool r18;
  final bool canOpen;
  final String? sourceUrl;
  final String? version;
  final String? pendingVersion;
  final String? availabilityLabel;
  final String? unavailableReason;

  bool get needsAttention => pendingVersion != null || (enabled && !canOpen);
  String get statusLabel => !enabled
      ? '已停用'
      : canOpen
      ? '已启用'
      : availabilityLabel ?? '等待激活';
}

class DataSourceManagementRow extends StatelessWidget {
  const DataSourceManagementRow({
    required this.source,
    required this.isPending,
    required this.onPressed,
    required this.onChanged,
    this.onDiscover,
    this.onSearch,
    this.onOpenSourceUrl,
    this.compact = false,
    super.key,
  });

  final DataSourceManagementRowData source;
  final bool isPending;
  final VoidCallback onPressed;
  final ValueChanged<bool> onChanged;
  final VoidCallback? onDiscover;
  final VoidCallback? onSearch;
  final VoidCallback? onOpenSourceUrl;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (TvModeScope.isEnabled(context)) {
      return TvDataSourceManagementRow(
        source: source,
        pending: isPending,
        onDetail: onPressed,
        onToggle: () => onChanged(!source.enabled),
        onDiscover: onDiscover,
        onSearch: onSearch,
        onOpenSourceUrl: onOpenSourceUrl,
      );
    }
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return Semantics(
      key: ValueKey<String>('data-source-${source.id}'),
      container: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadii.detailCard,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.regular),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    SizedBox.square(
                      key: ValueKey<String>('data-source-icon-${source.id}'),
                      dimension: AppSpacing.minimumTouchTarget,
                      child: _DataSourceBrandMark(
                        sourceId: source.id,
                        displayName: source.name,
                        brand: source.brand,
                        isDevelopment: source.isDevelopment,
                        iconUrl: source.iconUrl,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.regular),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(source.name, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: AppSpacing.unit),
                          Text(
                            '${source.kindLabel}${source.version == null ? '' : ' · v${source.version}'}',
                            style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.unit),
                    if (!source.isDevelopment)
                      Tooltip(
                        message: source.enabled ? '停用 ${source.name}' : '启用 ${source.name}',
                        child: Switch.adaptive(
                          key: ValueKey<String>('data-source-enabled-${source.id}'),
                          value: source.enabled,
                          onChanged: isPending ? null : onChanged,
                        ),
                      )
                    else
                      const Tooltip(message: '开发数据源由开发目录管理', child: Icon(Icons.code_rounded)),
                    const Icon(Icons.chevron_right_rounded, size: 18),
                  ],
                ),
                const SizedBox(height: AppSpacing.compact),
                Text(
                  isPending ? '正在处理，请稍候' : source.statusLabel,
                  key: ValueKey<String>('data-source-status-${source.id}'),
                  style: theme.textTheme.bodySmall?.copyWith(color: source.needsAttention ? tokens.notification : tokens.dataSourceAccent),
                ),
                if (source.pendingVersion != null)
                  Text('v${source.pendingVersion} 已下载，下次启动生效', style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
                if (source.enabled && !source.canOpen && source.unavailableReason != null)
                  Text(source.unavailableReason!, style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
                if (!compact) ...[
                  const SizedBox(height: AppSpacing.compact),
                  Text(
                    source.description,
                    key: ValueKey<String>('data-source-description-${source.id}'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText, height: 1.5),
                  ),
                  const SizedBox(height: AppSpacing.compact),
                  SelectableText(
                    source.sourceUrl ?? '未提供来源网址',
                    key: ValueKey<String>('data-source-url-${source.id}'),
                    style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                  ),
                ],
                Align(
                  alignment: Alignment.centerRight,
                  child: PopupMenuButton<String>(
                    key: ValueKey<String>('data-source-menu-${source.id}'),
                    tooltip: '${source.name}内容操作',
                    enabled: !isPending,
                    onSelected: (value) {
                      if (value == 'discover') onDiscover?.call();
                      if (value == 'search') onSearch?.call();
                      if (value == 'website') onOpenSourceUrl?.call();
                    },
                    itemBuilder: (_) => [
                      if (onDiscover != null)
                        PopupMenuItem(value: 'discover', enabled: source.canOpen && source.enabled, child: const Text('浏览内容')),
                      if (onSearch != null)
                        PopupMenuItem(value: 'search', enabled: source.canOpen && source.enabled, child: const Text('搜索内容')),
                      PopupMenuItem(value: 'website', enabled: onOpenSourceUrl != null, child: const Text('打开来源网站')),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.compact),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('内容与网站', style: theme.textTheme.labelMedium?.copyWith(color: tokens.mutedText)),
                          const SizedBox(width: AppSpacing.unit),
                          const Icon(Icons.more_horiz_rounded, size: 20),
                        ],
                      ),
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
    final Widget mark = SourceIcon(
      sourceId: sourceId,
      displayName: displayName,
      iconUrl: iconUrl,
      fallback: _GeneratedBrandMark(brand: brand),
      size: AppSpacing.dataSourceManagementMarkExtent,
      borderRadius: 12,
    );
    if (!isDevelopment) return mark;
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final ThemeData theme = Theme.of(context);
    return Semantics(
      label: '开发数据源插件',
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
              child: SizedBox(
                width: AppSpacing.regular,
                height: AppSpacing.regular,
                child: Icon(Icons.code_rounded, size: AppSpacing.compact, color: theme.colorScheme.onPrimary),
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
        width: AppSpacing.dataSourceManagementMarkExtent,
        height: AppSpacing.dataSourceManagementMarkExtent,
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
    DataSourceBrand.tomato => CustomPaint(
      size: const Size.square(AppSpacing.dataSourceManagementMarkExtent),
      painter: _TomatoMarkPainter(color),
    ),
    DataSourceBrand.qimao => CustomPaint(
      size: const Size.square(AppSpacing.dataSourceManagementMarkExtent),
      painter: _CatMarkPainter(color),
    ),
    DataSourceBrand.zongheng => _GridBrandGlyph(color: color),
    DataSourceBrand.jinjiang => CustomPaint(
      size: const Size.square(AppSpacing.dataSourceManagementMarkExtent),
      painter: _JinjiangMarkPainter(color),
    ),
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
    width: AppSpacing.dataSourceManagementMarkExtent - AppSpacing.regular,
    height: AppSpacing.dataSourceManagementMarkExtent - AppSpacing.regular,
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
    final double unit = size.width / AppSpacing.dataSourceManagementMarkExtent;
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
    final double unit = size.width / AppSpacing.dataSourceManagementMarkExtent;
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
    final double unit = size.width / AppSpacing.dataSourceManagementMarkExtent;
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
