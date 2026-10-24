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
library;

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
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints constraints) {
                      return Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          Opacity(
                            opacity: 0.84,
                            child: Transform.scale(
                              scale: 1.08,
                              child: LibraryBookCover(
                                key: const Key('library-home-top-backdrop-cover'),
                                title: data.title,
                                contentKind: data.contentKind,
                                variant: data.coverVariant,
                                coverBytes: data.coverBytes,
                                coverRequest: data.coverRequest,
                                assetPath: data.coverAssetPath,
                                isBlurred: data.isCoverBlurred,
                                alignment: Alignment.topCenter,
                                width: constraints.maxWidth,
                                height: constraints.maxHeight,
                                fit: BoxFit.cover,
                                showLetterboxBackground: false,
                              ),
                            ),
                          ),
                          DecoratedBox(
                            key: const Key('library-home-reading-readability-scrim'),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                                colors: <Color>[
                                  tokens.surface.withValues(alpha: 0.08),
                                  tokens.surface.withValues(alpha: 0.16),
                                  tokens.surface.withValues(alpha: 0.6),
                                  tokens.surface.withValues(alpha: 0.72),
                                ],
                                stops: const <double>[0, 0.34, 0.52, 1],
                              ),
                            ),
                          ),
                          DecoratedBox(
                            key: const Key('library-home-top-bottom-fade'),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: <Color>[
                                  Colors.transparent,
                                  Colors.transparent,
                                  tokens.pageBackground.withValues(alpha: 0.15),
                                  tokens.pageBackground.withValues(alpha: 0.6),
                                  tokens.pageBackground,
                                  tokens.pageBackground,
                                ],
                                // Finish on the actual page surface before the Sliver/clip edge.
                                stops: const <double>[0, 0.68, 0.78, 0.9, 0.97, 1],
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
          child,
        ],
      ),
    );
  }
}
