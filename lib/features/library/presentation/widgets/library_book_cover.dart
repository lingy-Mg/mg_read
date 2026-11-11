/// 书架书籍的异步封面组件。
///
/// 职责：
/// - 立即展示封面加载状态或本地降级插画。
/// - 使用共享封面请求在字节就绪后独立刷新图片。
///
/// 注意：
/// - 书架概览不得等待封面读取完成。
/// - 本地资源和已提供的封面字节优先于异步请求。
/// - 首次可见封面向首页就绪边界报告解码状态，图片按显示宽度限制解码尺寸。
/// - 取图和解码共用状态反馈；刷新保留旧图，刷新反馈层不参与隐私模糊。
///
library;

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/widgets/app_cover_image.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_first_frame.dart';
import 'package:mg_read/shared/presentation/widgets/default_content_cover_artwork.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';
import 'package:mg_read/shared/presentation/widgets/local_document_image.dart';

/// 独立于书架概览加载的本地书籍封面。
class LibraryBookCover extends ConsumerWidget {
  /// Creates a themed cover placeholder for [title].
  const LibraryBookCover({
    required this.title,
    required this.variant,
    required this.width,
    required this.height,
    this.contentKind = ContentKind.novel,
    this.assetPath,
    this.coverBytes,
    this.coverRequest,
    this.fit = BoxFit.contain,
    this.useIntrinsicAspectRatio = false,
    this.showLetterboxBackground = true,
    this.isRefreshing = false,
    this.isBlurred = false,
    this.clipToBounds = true,
    this.alignment = Alignment.center,
    super.key,
  });

  final String title;
  final ContentKind contentKind;
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

  /// Clips the cover to its standard rounded rectangle and bounds.
  ///
  /// Disable only when a parent paints the cover as a full-bleed background
  /// and owns the visible fade at its edge.
  final bool clipToBounds;
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
    final isSvg = bytes != null && isLocalSvgImage(bytes);
    final ImageProvider? originalImage = isSvg
        ? null
        : bytes != null && bytes.isNotEmpty
        ? MemoryImage(normalizeBookCoverBytes(bytes))
        : assetPath == null
        ? null
        : AssetImage(assetPath!);
    final decodeWidth = width.isFinite && width > 0 ? (width * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(1, 1024) : null;
    final image = originalImage == null ? null : ResizeImage.resizeIfNeeded(decodeWidth, null, originalImage);

    final failed =
        asyncBytes?.hasError == true ||
        (asyncBytes is AsyncData<List<int>?> && !hasImage && ref.watch(bookCoverBytesLoaderProvider) is! EmptyBookCoverBytesLoader);
    final label = isBlurred ? '$title 的模糊封面' : '$title 的封面';
    final placeholder = _sizedPlaceholder(tokens, start, end);
    final svg = isSvg
        ? LocalDocumentImage(
            bytes,
            width: imageWidth,
            height: imageHeight,
            fit: imageFit,
            semanticLabel: label,
            loadingPlaceholder: AppCoverFeedback(state: AppCoverState.loading, label: label, child: placeholder),
            fallback: AppCoverFeedback(state: AppCoverState.failed, label: label, child: placeholder),
          )
        : null;
    final background = useIntrinsicAspectRatio || !showLetterboxBackground ? null : letterboxColor;
    final Widget rendered;
    if (svg != null) {
      final content = _imageFrame(svg, backgroundColor: background);
      rendered = isRefreshing ? AppCoverFeedback(state: AppCoverState.refreshing, label: label, child: content) : content;
    } else {
      rendered = AppCoverImage(
        image: image,
        label: label,
        placeholder: placeholder,
        loading: isLoading || isRefreshing,
        failed: failed,
        width: imageWidth,
        height: imageHeight,
        fit: imageFit,
        alignment: alignment,
        frameBuilder: (context, child, frame, synchronous) => _imageFrame(
          transparentContainedImage ? _buildTransparentContainedFrame(context, child, frame, synchronous) : child,
          backgroundColor: background,
        ),
      );
    }
    return LibraryCoverFirstFrame(
      loading: isLoading,
      image: image,
      child: MergeSemantics(
        child: SizedBox(
          width: width,
          height: useIntrinsicAspectRatio && hasImage ? null : height,
          child: clipToBounds ? ClipRRect(borderRadius: AppRadii.bookCover, child: rendered) : rendered,
        ),
      ),
    );
  }

  Widget _imageFrame(Widget image, {Color? backgroundColor}) {
    final content = backgroundColor == null ? image : ColoredBox(color: backgroundColor, child: image);
    if (!isBlurred) {
      return content;
    }

    // Standard book cards overscan before clipping to keep privacy-blur edges
    // filled. Full-bleed backgrounds can disable that card treatment and own
    // their bounds and fade at the call site.
    final Widget filtered = ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
      child: clipToBounds ? Transform.scale(scale: 1.18, child: content) : content,
    );
    return filtered;
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

  Widget _sizedPlaceholder(AppThemeTokens tokens, Color start, Color end) => SizedBox(
    width: width,
    height: height,
    child: DefaultContentCoverArtwork(
      kind: _defaultCoverKind(contentKind),
      title: title,
      width: width,
      height: height,
      startColor: start,
      endColor: end,
      foregroundColor: tokens.featureSurface.withValues(alpha: .96),
      borderRadius: clipToBounds ? BorderRadius.zero : AppRadii.bookCover,
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

DefaultCoverKind _defaultCoverKind(ContentKind kind) => switch (kind) {
  ContentKind.novel => DefaultCoverKind.novel,
  ContentKind.manga => DefaultCoverKind.manga,
  ContentKind.audio => DefaultCoverKind.audio,
  ContentKind.video => DefaultCoverKind.video,
};
