/// 通用内容默认封面。
///
/// 职责：
/// - 在来源封面缺失或无法解码时，以本地绘制的极简图形表达内容类型。
/// - 复用调用方已选定的主题封面配色，不引入图片资产或独立配色系统。
///
/// 注意：
/// - 紧凑封面只显示类型，避免与卡片外的作品标题重复。
/// - 宽度至少 144 且高度至少 180 时，才在封面底部显示最多两行标题。
/// - 文字使用高对比底板，避免浅色渐变吞没类型或标题；图形沿用传入前景色。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The four content families supported by MgRead's local fallback artwork.
enum DefaultCoverKind { novel, manga, audio, video }

extension DefaultCoverKindPresentation on DefaultCoverKind {
  String get label => switch (this) {
    DefaultCoverKind.novel => '小说',
    DefaultCoverKind.manga => '漫画',
    DefaultCoverKind.audio => '音频',
    DefaultCoverKind.video => '视频',
  };

  IconData get icon => switch (this) {
    DefaultCoverKind.novel => Icons.menu_book_rounded,
    DefaultCoverKind.manga => Icons.photo_library_rounded,
    DefaultCoverKind.audio => Icons.headphones_rounded,
    DefaultCoverKind.video => Icons.play_circle_fill_rounded,
  };
}

/// Locally drawn, type-aware artwork used when source cover art is unavailable.
class DefaultContentCoverArtwork extends StatelessWidget {
  const DefaultContentCoverArtwork({
    required this.kind,
    required this.title,
    required this.width,
    required this.height,
    required this.startColor,
    required this.endColor,
    required this.foregroundColor,
    required this.borderRadius,
    super.key,
  });

  final DefaultCoverKind kind;
  final String title;
  final double width;
  final double height;
  final Color startColor;
  final Color endColor;
  final Color foregroundColor;
  final BorderRadius borderRadius;

  bool get _showsKindLabel => width >= 52 && height >= 52;
  bool get _showsTitle => width >= 144 && height >= 180 && title.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final double shortestSide = math.min(width, height);
    final double inset = (shortestSide * 0.1).clamp(5.0, 22.0).toDouble();
    final double iconSize = (shortestSide * 0.3).clamp(14.0, 62.0).toDouble();
    final double iconSurfaceSize = (iconSize * 1.72).clamp(24.0, 104.0).toDouble();
    final Color quietStart = Color.lerp(startColor, endColor, 0.12)!;
    final Color quietEnd = Color.lerp(endColor, startColor, 0.05)!;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: <Color>[quietStart, quietEnd]),
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Align(
              alignment: _showsTitle ? const Alignment(0, -0.16) : Alignment.center,
              child: DecoratedBox(
                decoration: BoxDecoration(color: foregroundColor.withValues(alpha: 0.11), shape: BoxShape.circle),
                child: SizedBox.square(
                  dimension: iconSurfaceSize,
                  child: Icon(
                    kind.icon,
                    key: ValueKey<String>('default-cover-kind-${kind.name}'),
                    size: iconSize,
                    color: foregroundColor.withValues(alpha: 0.92),
                  ),
                ),
              ),
            ),
            if (_showsKindLabel)
              Positioned(
                left: inset,
                top: inset,
                child: _CoverTextPlate(
                  key: ValueKey<String>('default-cover-label-plate-${kind.name}'),
                  child: Text(
                    kind.label,
                    key: ValueKey<String>('default-cover-label-${kind.name}'),
                    maxLines: 1,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Colors.white,
                      fontSize: (shortestSide * 0.09).clamp(9.0, 13.0).toDouble(),
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ),
            if (_showsTitle)
              Positioned(
                left: inset,
                right: inset,
                bottom: inset,
                child: _CoverTextPlate(
                  key: const Key('default-cover-title-plate'),
                  child: Text(
                    title.trim(),
                    key: const Key('default-cover-title'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.left,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontSize: (width * 0.105).clamp(15.0, 24.0).toDouble(),
                      fontWeight: FontWeight.w700,
                      height: 1.12,
                      letterSpacing: 0.1,
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

class _CoverTextPlate extends StatelessWidget {
  const _CoverTextPlate({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(color: Color(0xA8000000), borderRadius: BorderRadius.all(Radius.circular(4))),
    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2), child: child),
  );
}
