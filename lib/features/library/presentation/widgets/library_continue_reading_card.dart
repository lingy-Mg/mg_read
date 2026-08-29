/// 继续阅读卡片。
///
/// 职责：
/// - 展示当前阅读条目及其独立加载的封面。
/// - 通过显式回调通知页面继续阅读。
///
/// 注意：
/// - 封面状态不得阻塞卡片正文或继续阅读操作。
/// - 不访问持久化、Runtime 或路由实现。
/// - 首页沉浸模式下封面居左并与顶部操作栏同高起始，书名、作者、简介与按钮居右。
///
/// TODO:
/// - 无。
library;

import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';

/// 仅由展示模型驱动的突出当前阅读卡片。
class LibraryContinueReadingCard extends StatelessWidget {
  /// Creates the current-reading card for [data].
  const LibraryContinueReadingCard({
    required this.data,
    required this.onContinueReading,
    this.isPreparing = false,
    this.showBackdrop = true,
    super.key,
  });

  final LibraryContinueReadingViewData data;
  final VoidCallback onContinueReading;
  final bool isPreparing;
  final bool showBackdrop;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      container: true,
      label: isPreparing ? '继续阅读，${data.title}，正在准备阅读内容' : '继续阅读，${data.title}',
      liveRegion: isPreparing,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool compact = constraints.maxWidth < AppSpacing.compactCardStackBreakpoint;
          final double textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.5);
          final double cardHeight = (showBackdrop ? (compact ? 172 : 196) : (compact ? 224 : 238)) + (textScale - 1) * 48;
          final double coverHeight = showBackdrop ? (compact ? 108 : 132) : (compact ? 216 : 230);
          final double coverWidth = coverHeight * 0.68;
          final double externalBottomInset = (cardHeight - coverHeight) / 2;
          final Widget content = Stack(
            children: <Widget>[
              if (showBackdrop) ...<Widget>[
                Positioned.fill(
                  child: ExcludeSemantics(
                    child: IgnorePointer(
                      child: ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                        child: Transform.scale(
                          scale: 1.18,
                          child: Opacity(
                            opacity: 0.46,
                            child: LibraryBookCover(
                              title: data.title,
                              variant: data.coverVariant,
                              coverBytes: data.coverBytes,
                              coverRequest: data.coverRequest,
                              assetPath: data.coverAssetPath,
                              width: constraints.maxWidth,
                              height: cardHeight,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: <Color>[
                          tokens.featureSurface.withValues(alpha: 0.98),
                          tokens.surface.withValues(alpha: 0.86),
                          tokens.surface.withValues(alpha: 0.54),
                        ],
                        stops: const <double>[0, 0.56, 1],
                      ),
                    ),
                  ),
                ),
              ],
              Positioned(
                left: showBackdrop ? null : 0,
                right: showBackdrop ? AppSpacing.comfortable : null,
                top: showBackdrop ? (cardHeight - coverHeight) / 2 : 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: AppRadii.bookCover,
                    boxShadow: <BoxShadow>[
                      BoxShadow(color: tokens.shadow.withValues(alpha: 0.18), blurRadius: 12, offset: const Offset(0, 5)),
                    ],
                  ),
                  child: LibraryBookCover(
                    key: const Key('continue-reading-flat-cover'),
                    title: data.title,
                    variant: data.coverVariant,
                    coverBytes: data.coverBytes,
                    coverRequest: data.coverRequest,
                    assetPath: data.coverAssetPath,
                    width: coverWidth,
                    height: coverHeight,
                  ),
                ),
              ),
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    showBackdrop ? AppSpacing.comfortable : coverWidth + AppSpacing.comfortable,
                    showBackdrop ? AppSpacing.comfortable : AppSpacing.minimumTouchTarget + AppSpacing.regular,
                    showBackdrop ? coverWidth + AppSpacing.page : 0,
                    showBackdrop ? AppSpacing.comfortable : externalBottomInset,
                  ),
                  child: _ContinueReadingDetails(
                    data: data,
                    onContinueReading: onContinueReading,
                    isPreparing: isPreparing,
                    showEyebrow: showBackdrop,
                  ),
                ),
              ),
            ],
          );
          final Widget sizedContent = SizedBox(
            key: const Key('continue-reading-surface'),
            height: cardHeight,
            width: double.infinity,
            child: showBackdrop ? ClipRRect(borderRadius: AppRadii.card, child: content) : content,
          );
          if (!showBackdrop) return sizedContent;
          return DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.featureSurface,
              borderRadius: AppRadii.card,
              border: Border.all(color: tokens.divider),
              boxShadow: <BoxShadow>[BoxShadow(color: tokens.shadow.withValues(alpha: 0.1), blurRadius: 18, offset: const Offset(0, 6))],
            ),
            child: sizedContent,
          );
        },
      ),
    );
  }
}

class _ContinueReadingDetails extends StatelessWidget {
  const _ContinueReadingDetails({
    required this.data,
    required this.onContinueReading,
    required this.isPreparing,
    required this.showEyebrow,
  });

  final LibraryContinueReadingViewData data;
  final VoidCallback onContinueReading;
  final bool isPreparing;
  final bool showEyebrow;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final String? author = _nonBlank(data.author);
    final String? description = _nonBlank(data.description);

    if (!showEyebrow) {
      final double textScale = MediaQuery.textScalerOf(context).scale(1);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            key: const Key('continue-reading-title'),
            data.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, height: 1.18, letterSpacing: -0.2),
          ),
          if (author != null) ...<Widget>[
            const SizedBox(height: AppSpacing.compact / 2),
            Text(
              key: const Key('continue-reading-author'),
              '作者 · $author',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface, fontWeight: FontWeight.w600, height: 1.25),
            ),
          ],
          if (description != null) ...<Widget>[
            const SizedBox(height: AppSpacing.compact / 2),
            Expanded(
              child: Align(
                alignment: Alignment.topLeft,
                child: Text(
                  key: const Key('continue-reading-description'),
                  description,
                  maxLines: textScale > 1.25 ? 2 : 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface, height: 1.35),
                ),
              ),
            ),
          ] else
            const Spacer(),
          const SizedBox(height: AppSpacing.compact),
          Align(
            alignment: Alignment.center,
            child: _ContinueReadingAction(onPressed: onContinueReading, isPreparing: isPreparing, progress: data.progress),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: showEyebrow ? MainAxisAlignment.start : MainAxisAlignment.end,
      children: <Widget>[
        if (showEyebrow) ...<Widget>[
          Text(
            '继续阅读',
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.accent, fontWeight: FontWeight.w600, letterSpacing: 0.3),
          ),
          const SizedBox(height: AppSpacing.compact),
        ],
        Text(
          key: const Key('continue-reading-title'),
          data.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, height: 1.18, letterSpacing: -0.2),
        ),
        if (showEyebrow) const Spacer() else const SizedBox(height: AppSpacing.comfortable),
        Align(
          alignment: Alignment.center,
          child: _ContinueReadingAction(onPressed: onContinueReading, isPreparing: isPreparing, progress: data.progress),
        ),
      ],
    );
  }
}

String? _nonBlank(String? value) {
  final String? trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

class _ContinueReadingAction extends StatelessWidget {
  const _ContinueReadingAction({required this.onPressed, required this.isPreparing, required this.progress});

  final VoidCallback onPressed;
  final bool isPreparing;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final int percentage = (progress * 100).round();
    return Semantics(
      button: true,
      label: '阅读进度 $percentage%',
      value: '$percentage%',
      onTap: isPreparing ? null : onPressed,
      child: ExcludeSemantics(
        child: SizedBox(
          width: 136,
          height: 42,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: AppRadii.continueReadingAction,
              boxShadow: <BoxShadow>[BoxShadow(color: tokens.accent.withValues(alpha: 0.24), blurRadius: 10, offset: const Offset(0, 4))],
            ),
            child: ClipRRect(
              borderRadius: AppRadii.continueReadingAction,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  ColoredBox(color: tokens.accent.withValues(alpha: 0.38)),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      key: const Key('continue-reading-cta-progress'),
                      widthFactor: progress,
                      heightFactor: 1,
                      child: ColoredBox(color: tokens.accent),
                    ),
                  ),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      key: const Key('continue-reading-cta'),
                      onTap: isPreparing ? null : onPressed,
                      child: Center(
                        child: isPreparing
                            ? SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.onPrimary),
                              )
                            : Text(
                                '继续阅读',
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: theme.colorScheme.onPrimary,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  height: 1.2,
                                ),
                              ),
                      ),
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
