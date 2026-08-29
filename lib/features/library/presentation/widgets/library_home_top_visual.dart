/// 首页顶部封面背景。
///
/// 职责：
/// - 将继续阅读封面扩展为顶部标题、菜单和主视觉的共享背景。
/// - 通过轻微柔化与大范围底部透明渐变衔接下方内容。
///
/// 注意：
/// - 背景与平面封面必须复用同一封面请求，不引入第二套缓存。
/// - 本组件不拥有首页交互或阅读状态。
///
/// TODO:
/// - 无。
library;

import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';

/// Full-width cover artwork behind the complete home header area.
class LibraryHomeTopVisual extends StatelessWidget {
  const LibraryHomeTopVisual({required this.continueReading, required this.child, super.key});

  final LibraryContinueReadingViewData? continueReading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final LibraryContinueReadingViewData? data = continueReading;
    return ClipRect(
      key: const Key('library-home-top-backdrop'),
      child: Stack(
        children: <Widget>[
          if (data == null)
            Positioned.fill(child: ColoredBox(color: tokens.featureSurface))
          else
            Positioned.fill(
              child: ShaderMask(
                key: const Key('library-home-top-bottom-fade'),
                blendMode: BlendMode.dstIn,
                shaderCallback: (Rect bounds) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[Colors.white, Colors.white, Colors.transparent],
                  stops: <double>[0, 0.78, 1],
                ).createShader(bounds),
                child: ExcludeSemantics(
                  child: IgnorePointer(
                    child: LayoutBuilder(
                      builder: (BuildContext context, BoxConstraints constraints) {
                        return Stack(
                          fit: StackFit.expand,
                          children: <Widget>[
                            Opacity(
                              opacity: 0.84,
                              child: ImageFiltered(
                                imageFilter: ImageFilter.blur(sigmaX: 2.4, sigmaY: 2.4),
                                child: Transform.scale(
                                  scale: 1.08,
                                  child: LibraryBookCover(
                                    key: const Key('library-home-top-backdrop-cover'),
                                    title: data.title,
                                    variant: data.coverVariant,
                                    coverBytes: data.coverBytes,
                                    coverRequest: data.coverRequest,
                                    assetPath: data.coverAssetPath,
                                    alignment: Alignment.topCenter,
                                    width: constraints.maxWidth,
                                    height: constraints.maxHeight,
                                  ),
                                ),
                              ),
                            ),
                            DecoratedBox(
                              key: const Key('library-home-left-readability-scrim'),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.centerLeft,
                                  end: Alignment.centerRight,
                                  colors: <Color>[
                                    tokens.surface.withValues(alpha: 0.34),
                                    tokens.surface.withValues(alpha: 0.12),
                                    Colors.transparent,
                                  ],
                                  stops: const <double>[0, 0.48, 0.76],
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          child,
        ],
      ),
    );
  }
}
