/// 书架书籍的异步封面组件。
///
/// 职责：
/// - 立即展示封面加载状态或本地降级插画。
/// - 使用共享封面请求在字节就绪后独立刷新图片。
///
/// 注意：
/// - 书架概览不得等待封面读取完成。
/// - 本地资源和已提供的封面字节优先于异步请求。
///
library;

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/shared/presentation/widgets/default_book_cover_artwork.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

/// 独立于书架概览加载的本地书籍封面。
class LibraryBookCover extends ConsumerWidget {
  /// Creates a themed cover placeholder for [title].
  const LibraryBookCover({
    required this.title,
    required this.variant,
    required this.width,
    required this.height,
    this.assetPath,
    this.coverBytes,
    this.coverRequest,
    this.fit = BoxFit.contain,
    this.useIntrinsicAspectRatio = false,
    this.showLetterboxBackground = true,
    this.isRefreshing = false,
    this.isBlurred = false,
    this.alignment = Alignment.center,
    super.key,
  });

  final String title;
  final LibraryCoverVariant variant;
  final double width;
  final double height;
  final String? assetPath;
  final List<int>? coverBytes;
  final BookCoverRequest? coverRequest;
  final BoxFit fit;
  final bool useIntrinsicAspectRatio;
  final bool showLetterboxBackground;

  /// Shows a transient overlay while the source refreshes this cover.
  final bool isRefreshing;
  final bool isBlurred;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final (Color start, Color end) = _gradientFor(tokens);
    final List<int>? suppliedBytes = coverBytes?.isNotEmpty ?? false ? coverBytes : null;
    final List<int>? cachedBytes = suppliedBytes == null && coverRequest != null ? BookCoverMemoryCache.peek(coverRequest!) : null;
    final asyncBytes = suppliedBytes == null && cachedBytes == null && coverRequest != null
        ? ref.watch(bookCoverBytesProvider(coverRequest!))
        : null;
    final List<int>? loadedBytes = switch (asyncBytes) {
      AsyncData<List<int>?>(:final value) => value,
      _ => null,
    };
    final bytes = suppliedBytes ?? cachedBytes ?? loadedBytes;
    final isLoading = (bytes?.isNotEmpty ?? false) == false && (isRefreshing || asyncBytes?.isLoading == true);
    final letterboxColor = Color.alphaBlend(start.withValues(alpha: 0.1), tokens.mutedSurface);
    final hasImage = (bytes?.isNotEmpty ?? false) || assetPath != null;
    final transparentContainedImage = !useIntrinsicAspectRatio && !showLetterboxBackground && fit == BoxFit.contain;
    final imageWidth = transparentContainedImage ? null : width;
    final imageHeight = useIntrinsicAspectRatio || transparentContainedImage ? null : height;
    final imageFit = transparentContainedImage
        ? BoxFit.fill
        : useIntrinsicAspectRatio
        ? BoxFit.fitWidth
        : fit;

    return Semantics(
      image: true,
      label: isRefreshing || isLoading
          ? '$title 的封面刷新中'
          : isBlurred
          ? '$title 的模糊封面'
          : '$title 的封面',
      child: ExcludeSemantics(
        child: SizedBox(
          width: width,
          height: useIntrinsicAspectRatio && hasImage ? null : height,
          child: Stack(
            fit: useIntrinsicAspectRatio && hasImage ? StackFit.loose : StackFit.expand,
            children: <Widget>[
              bytes != null && bytes.isNotEmpty
                  ? _imageFrame(
                      Image.memory(
                        normalizeBookCoverBytes(bytes),
                        width: imageWidth,
                        height: imageHeight,
                        fit: imageFit,
                        alignment: alignment,
                        gaplessPlayback: true,
                        excludeFromSemantics: true,
                        frameBuilder: transparentContainedImage ? _buildTransparentContainedFrame : null,
                        errorBuilder: (context, error, stackTrace) => _sizedPlaceholder(tokens, start, end),
                      ),
                      backgroundColor: useIntrinsicAspectRatio || !showLetterboxBackground ? null : letterboxColor,
                    )
                  : assetPath == null
                  ? _placeholder(tokens, start, end, isLoading: isLoading)
                  : _imageFrame(
                      Image.asset(
                        assetPath!,
                        width: imageWidth,
                        height: imageHeight,
                        fit: imageFit,
                        alignment: alignment,
                        excludeFromSemantics: true,
                        frameBuilder: transparentContainedImage ? _buildTransparentContainedFrame : null,
                        errorBuilder: (context, error, stackTrace) => _sizedPlaceholder(tokens, start, end),
                      ),
                      backgroundColor: useIntrinsicAspectRatio || !showLetterboxBackground ? null : letterboxColor,
                    ),
              if (isRefreshing && ((bytes?.isNotEmpty ?? false) || assetPath != null)) _refreshOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _imageFrame(Widget image, {Color? backgroundColor}) {
    final content = backgroundColor == null ? image : ColoredBox(color: backgroundColor, child: image);
    if (!isBlurred) {
      return ClipRRect(borderRadius: AppRadii.bookCover, child: content);
    }

    // Let the filtered pixels bleed past the final clip. Without this small
    // overscan, the blur samples the transparent area outside the image and
    // leaves a hard rectangular edge around the privacy cover.
    return ClipRRect(
      borderRadius: AppRadii.bookCover,
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Transform.scale(scale: 1.18, child: content),
      ),
    );
  }

  Widget _buildTransparentContainedFrame(BuildContext context, Widget child, int? frame, bool wasSynchronouslyLoaded) {
    if (child is! RawImage || child.image == null) return child;
    final image = child.image!;
    return Align(
      alignment: alignment,
      child: AspectRatio(
        aspectRatio: image.width / image.height,
        child: ClipRRect(key: const Key('book-cover-image-clip'), borderRadius: AppRadii.bookCover, child: child),
      ),
    );
  }

  Widget _sizedPlaceholder(AppThemeTokens tokens, Color start, Color end) =>
      SizedBox(width: width, height: height, child: _placeholder(tokens, start, end, isLoading: false));

  Widget _placeholder(AppThemeTokens tokens, Color start, Color end, {required bool isLoading}) {
    final foreground = tokens.featureSurface.withValues(alpha: 0.96);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        DefaultBookCoverArtwork(
          title: title,
          width: width,
          height: height,
          startColor: start,
          endColor: end,
          foregroundColor: foreground,
          borderRadius: AppRadii.bookCover,
        ),
        if (isLoading)
          ColoredBox(
            color: Colors.black.withValues(alpha: 0.16),
            child: Center(
              child: SizedBox(
                width: width >= 80 ? 22 : 16,
                height: width >= 80 ? 22 : 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
              ),
            ),
          ),
      ],
    );
  }

  Widget _refreshOverlay() => ColoredBox(
    color: Colors.black.withValues(alpha: 0.22),
    child: Center(
      child: SizedBox(
        width: width >= 80 ? 22 : 16,
        height: width >= 80 ? 22 : 16,
        child: const CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      ),
    ),
  );

  (Color, Color) _gradientFor(AppThemeTokens tokens) {
    return switch (variant) {
      LibraryCoverVariant.dusk => (tokens.coverDuskStart, tokens.coverDuskEnd),
      LibraryCoverVariant.dawn => (tokens.coverDawnStart, tokens.coverDawnEnd),
      LibraryCoverVariant.ocean => (tokens.coverOceanStart, tokens.coverOceanEnd),
      LibraryCoverVariant.indigo => (tokens.coverIndigoStart, tokens.coverIndigoEnd),
      LibraryCoverVariant.ember => (tokens.coverEmberStart, tokens.coverEmberEnd),
    };
  }
}
