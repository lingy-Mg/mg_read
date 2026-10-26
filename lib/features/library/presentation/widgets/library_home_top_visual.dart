/// 首页顶部封面背景。
///
/// 职责：
/// - 在顶部内容自身的布局范围内绘制继续阅读封面背景。
/// - 提供首页背景图与七种实时模糊效果预览切换。
///
/// 注意：
/// - 背景与平面封面复用同一封面请求，不引入第二套缓存。
/// - 图片按组件约束绘制，不进行越界放大或裁切。
/// - 仅拥有本地效果预览选择，不拥有阅读状态。
///
library;

import 'dart:ui';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';

/// Full-width cover artwork behind the complete home header area.
class LibraryHomeTopVisual extends StatefulWidget {
  const LibraryHomeTopVisual({required this.continueReading, required this.child, super.key});

  final LibraryContinueReadingViewData? continueReading;
  final Widget child;

  @override
  State<LibraryHomeTopVisual> createState() => _LibraryHomeTopVisualState();
}

// 保留七档效果，方便调试期间比较，后续需要时可继续启用。
enum _BackdropStyle { gentle, strong, frosted, softFocus, subtle, verySubtle, clear }

class _LibraryHomeTopVisualState extends State<LibraryHomeTopVisual> {
  // 正式版本默认使用微模糊；其他效果只用于调试预览。
  _BackdropStyle _style = _BackdropStyle.subtle;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final LibraryContinueReadingViewData? data = widget.continueReading;
    if (data == null) {
      return ColoredBox(key: const Key('library-home-top-backdrop'), color: tokens.featureSurface, child: widget.child);
    }
    final double sigma = switch (_style) {
      _BackdropStyle.gentle => 10,
      _BackdropStyle.strong => 26,
      _BackdropStyle.frosted => 18,
      _BackdropStyle.softFocus => 6,
      _BackdropStyle.subtle => 4,
      _BackdropStyle.verySubtle => 2,
      _BackdropStyle.clear => 0,
    };
    final double? tintAlpha = switch (_style) {
      _BackdropStyle.frosted => 0.26,
      _BackdropStyle.softFocus => 0.08,
      _ => null,
    };
    return ColoredBox(
      key: const Key('library-home-top-backdrop'),
      color: tokens.pageBackground,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) => Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      ClipRect(
                        child: ImageFiltered(
                          imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp),
                          child: LibraryBookCover(
                            key: const Key('library-home-top-backdrop-cover'),
                            title: data.title,
                            contentKind: data.contentKind,
                            variant: data.coverVariant,
                            coverBytes: data.coverBytes,
                            coverRequest: data.coverRequest,
                            assetPath: data.coverAssetPath,
                            isBlurred: false,
                            clipToBounds: false,
                            alignment: Alignment.center,
                            width: constraints.maxWidth,
                            height: constraints.maxHeight,
                            fit: BoxFit.cover,
                            showLetterboxBackground: false,
                          ),
                        ),
                      ),
                      if (tintAlpha != null) ColoredBox(color: tokens.surface.withValues(alpha: tintAlpha)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: ShaderMask(
                  key: const Key('library-home-reading-readability-scrim'),
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (Rect bounds) => const RadialGradient(
                    center: Alignment(0.52, 0.16),
                    radius: 0.82,
                    colors: <Color>[Color(0xF2FFFFFF), Color(0xCCFFFFFF), Color(0x00FFFFFF)],
                    stops: <double>[0, 0.7, 1],
                  ).createShader(bounds),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30, tileMode: TileMode.clamp),
                    child: ColoredBox(color: tokens.surface.withValues(alpha: 0.38)),
                  ),
                ),
              ),
            ),
          ),
          // 仅向下延伸 2px 到“最近阅读”上方留白，用于补齐边界，不覆盖标题内容。
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            bottom: -2,
            child: IgnorePointer(
              child: DecoratedBox(
                key: const Key('library-home-top-bottom-fade'),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Colors.transparent,
                      Colors.transparent,
                      tokens.pageBackground.withValues(alpha: 0.06),
                      tokens.pageBackground.withValues(alpha: 0.18),
                      tokens.pageBackground.withValues(alpha: 0.38),
                      tokens.pageBackground.withValues(alpha: 0.66),
                      tokens.pageBackground,
                      tokens.pageBackground,
                    ],
                    stops: const <double>[0, 0.72, 0.76, 0.8, 0.84, 0.88, 0.9, 1],
                  ),
                ),
              ),
            ),
          ),
          widget.child,
          if (kDebugMode)
            Positioned(
              left: 12,
              right: 12,
              bottom: 2,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.surface.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: tokens.divider.withValues(alpha: 0.55)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width - 24),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            _buildStyleButton(context, _BackdropStyle.gentle, '1 轻柔'),
                            _buildStyleButton(context, _BackdropStyle.strong, '2 重度'),
                            _buildStyleButton(context, _BackdropStyle.frosted, '3 毛玻璃'),
                            _buildStyleButton(context, _BackdropStyle.softFocus, '4 柔焦'),
                            _buildStyleButton(context, _BackdropStyle.subtle, '5 微模糊'),
                            _buildStyleButton(context, _BackdropStyle.verySubtle, '6 极轻'),
                            _buildStyleButton(context, _BackdropStyle.clear, '7 清晰'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStyleButton(BuildContext context, _BackdropStyle style, String label) {
    final bool selected = _style == style;
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: '背景效果 $label',
      child: InkWell(
        key: ValueKey<String>('library-home-backdrop-style-${style.name}'),
        borderRadius: BorderRadius.circular(20),
        onTap: () => setState(() => _style = style),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? tokens.accent.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: selected ? tokens.accent : tokens.mutedText,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
