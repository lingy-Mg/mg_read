import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';

/// Stable app-owned presentation metadata for well-known bundled sources.
///
/// The Runtime remains the authority for whether a source is installed and
/// enabled. This small catalog only supplies a safe visual fallback when an
/// older installed package has not published optional descriptive metadata.
abstract final class SourceBranding {
  static const String aliceId = 'org.mgread.aisishuwu';
  static const String shuduguId = 'org.mgread.shudugu';

  static String? assetFor(String sourceId) => switch (sourceId) {
    aliceId => 'assets/data_sources/aisishuwu.webp',
    shuduguId => 'assets/data_sources/shudugu.webp',
    _ => null,
  };

  static String? fallbackDescription(String sourceId, {String? displayName}) => switch (sourceId) {
    aliceId => '成人向原创网络小说数据源，覆盖分类、排行、搜索与章节阅读。',
    shuduguId => '轻量快速的网络小说数据源，提供分类发现、搜索、详情、目录与正文阅读。',
    _ => switch (displayName) {
      '起点中文网' => '阅文集团旗下原创文学平台',
      '番茄小说' => '今日头条旗下免费小说平台',
      '七猫中文网' => '海量正版小说，永久免费阅读',
      '纵横中文网' => '精品原创小说阅读平台',
      '晋江文学城' => '女性向原创文学网站',
      '17K 小说网' => '中文在线旗下阅读平台',
      '潇湘书院' => '专注女性原创小说平台',
      '飞卢小说网' => '原创小说首发网站',
      '豆瓣阅读' => '优质原创作品阅读平台',
      '书旗小说' => '阿里文学旗下阅读平台',
      '刺猬猫阅读' => '二次元小说阅读平台',
      '掌阅精选' => '掌阅科技旗下阅读平台',
      _ => null,
    },
  };

  static String description({required String sourceId, String? displayName, String? value}) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty
        ? fallbackDescription(sourceId, displayName: displayName) ?? '提供小说内容发现与阅读。'
        : normalized;
  }
}

/// Prefers the Runtime-published icon and falls back to app-owned branding or
/// the caller's generated brand mark when the remote icon is unavailable.
class SourceIcon extends StatelessWidget {
  const SourceIcon({
    required this.sourceId,
    required this.displayName,
    required this.iconUrl,
    this.fallback,
    this.size = 40,
    this.borderRadius = 10,
    super.key,
  });

  final String sourceId;
  final String displayName;
  final String? iconUrl;
  final Widget? fallback;
  final double size;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final asset = SourceBranding.assetFor(sourceId);
    final Widget fallbackIcon = asset == null
        ? fallback ?? _FallbackSourceIcon(displayName: displayName, size: size, borderRadius: borderRadius)
        : ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius),
            child: Image.asset(asset, width: size, height: size, fit: BoxFit.cover),
          );
    final Uri? iconUri = Uri.tryParse(iconUrl ?? '');
    if (iconUri == null || (iconUri.scheme != 'http' && iconUri.scheme != 'https')) return fallbackIcon;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Image.network(
        iconUri.toString(),
        key: ValueKey<String>('source-icon-network-$sourceId'),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallbackIcon,
      ),
    );
  }
}

class _FallbackSourceIcon extends StatelessWidget {
  const _FallbackSourceIcon({required this.displayName, required this.size, required this.borderRadius});

  final String displayName;
  final double size;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final glyph = displayName.isEmpty ? '源' : displayName.characters.first;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: <Color>[tokens.accent, tokens.accent.withValues(alpha: 0.72)]),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Text(
            glyph,
            style: TextStyle(color: Colors.white, fontSize: size * 0.42, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }
}
