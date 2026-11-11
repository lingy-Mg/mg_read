/// 数据源内容的异步封面组件。
///
/// 职责：
/// - 取图和解码期间保留加载占位，缺图与失败明确结束等待。
/// - 复用共享请求键，避免相同封面在同一页面重复加载。
///
/// 注意：
/// - 加载或失败不得延迟父列表、发现页或详情页的首次显示。
/// - 默认插画、失败标记与首次显示过渡由共享封面状态组件提供。
///
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/widgets/app_cover_image.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/shared/presentation/widgets/default_content_cover_artwork.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

/// Host rendering shape selected from the source's cover-orientation contract.
///
/// This is independent from media kind. It only controls presentation; source
/// URLs and decoded bytes keep their existing typed boundary.
enum DiscoveryCoverPresentation { portrait, square, landscape }

/// 显示不阻塞周边内容的数据源封面。
class DiscoveryBookCover extends ConsumerWidget {
  const DiscoveryBookCover({
    required this.title,
    required this.variant,
    this.contentKind = PluginContentKind.novel,
    this.width,
    this.height,
    this.presentation = DiscoveryCoverPresentation.portrait,
    this.coverBytes,
    this.remoteContentId,
    this.coverUrl,
    super.key,
  }) : assert(width != null || height != null, 'DiscoveryBookCover needs a width or height constraint.');

  final String title;
  final DiscoveryCoverVariant variant;
  final PluginContentKind contentKind;

  /// A fixed presentation width for constrained placements such as grids.
  ///
  /// At least one dimension must be provided. When only [height] is set, a
  /// decoded cover determines the width from its intrinsic aspect ratio.
  final double? width;

  /// A fixed presentation height for constrained placements such as shelves.
  ///
  /// When omitted, decoded source art determines the height after its width is
  /// constrained. This preserves the original cover ratio in flowing grids.
  final double? height;
  final DiscoveryCoverPresentation presentation;
  final List<int>? coverBytes;
  final String? remoteContentId;
  final Uri? coverUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final (Color start, Color end) = _gradient(tokens);
    final scope = BookCoverSourceScope.maybeOf(context);
    final request = scope == null || remoteContentId == null || coverUrl == null
        ? null
        : scope.requestFor(remoteContentId: remoteContentId!, coverUrl: coverUrl!);
    final suppliedBytes = coverBytes?.isNotEmpty == true ? coverBytes : null;
    final cachedBytes = suppliedBytes == null && request != null ? BookCoverMemoryCache.peek(request) : null;
    final asyncBytes = request == null || suppliedBytes != null || cachedBytes != null ? null : ref.watch(bookCoverBytesProvider(request));
    final loadedBytes = switch (asyncBytes) {
      AsyncData<List<int>?>(:final value) => value,
      _ => null,
    };
    final bytes = suppliedBytes ?? cachedBytes ?? loadedBytes;
    final hasCoverBytes = bytes?.isNotEmpty == true;
    final isLoading = !hasCoverBytes && asyncBytes?.isLoading == true;
    final failed =
        asyncBytes?.hasError == true ||
        (asyncBytes is AsyncData<List<int>?> && !hasCoverBytes && ref.watch(bookCoverBytesLoaderProvider) is! EmptyBookCoverBytesLoader);
    final placeholder = SizedBox(width: _placeholderWidth, height: _placeholderHeight, child: _placeholder(tokens.surface, start, end));
    final label = '$title 的封面';
    return MergeSemantics(
      child: SizedBox(
        width: width,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: _borderRadius,
            boxShadow: [
              BoxShadow(color: tokens.shadow, blurRadius: _visualWidth >= 80 ? 8 : 3, offset: Offset(0, _visualWidth >= 80 ? 4 : 1.5)),
            ],
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [start, end]),
          ),
          child: ClipRRect(
            borderRadius: _borderRadius,
            child: hasCoverBytes && (width == null || height == null)
                ? _IntrinsicCoverImage(
                    bytes: normalizeBookCoverBytes(bytes!),
                    fallbackAspectRatio: _fallbackAspectRatio,
                    placeholder: placeholder,
                    label: label,
                  )
                : AppCoverImage(
                    image: hasCoverBytes ? MemoryImage(normalizeBookCoverBytes(bytes!)) : null,
                    placeholder: placeholder,
                    label: label,
                    loading: isLoading,
                    failed: failed,
                    width: width,
                    height: height,
                  ),
          ),
        ),
      ),
    );
  }

  double get _visualWidth => width ?? _placeholderWidth;

  double get _placeholderWidth => width ?? height! / _fallbackAspectRatio;

  double get _placeholderHeight => height ?? width! * _fallbackAspectRatio;

  double get _fallbackAspectRatio => switch (presentation) {
    DiscoveryCoverPresentation.portrait => AppSpacing.discoveryCoverAspectRatio,
    DiscoveryCoverPresentation.square => 1,
    DiscoveryCoverPresentation.landscape => 9 / 16,
  };

  Widget _placeholder(Color foreground, Color start, Color end) => DefaultContentCoverArtwork(
    kind: _defaultCoverKind(contentKind),
    title: title,
    width: _visualWidth,
    height: _placeholderHeight,
    startColor: start,
    endColor: end,
    foregroundColor: foreground,
    borderRadius: _borderRadius,
  );

  (Color, Color) _gradient(AppThemeTokens tokens) {
    return switch (variant) {
      DiscoveryCoverVariant.gothic => (tokens.coverDuskStart, tokens.coverDuskEnd),
      DiscoveryCoverVariant.dawn => (tokens.coverDawnStart, tokens.coverDawnEnd),
      DiscoveryCoverVariant.indigo => (tokens.coverIndigoEnd, tokens.coverOceanStart),
      DiscoveryCoverVariant.ember => (tokens.coverEmberEnd, tokens.coverEmberStart),
      DiscoveryCoverVariant.snow => (tokens.featureSurface, tokens.coverDawnEnd),
      DiscoveryCoverVariant.abyss => (tokens.coverOceanStart, tokens.coverIndigoStart),
    };
  }

  BorderRadius get _borderRadius =>
      presentation == DiscoveryCoverPresentation.landscape ? BorderRadius.circular(10) : AppRadii.discoveryCover;
}

DefaultCoverKind _defaultCoverKind(PluginContentKind kind) => switch (kind) {
  PluginContentKind.novel => DefaultCoverKind.novel,
  PluginContentKind.manga => DefaultCoverKind.manga,
  PluginContentKind.audio => DefaultCoverKind.audio,
  PluginContentKind.video => DefaultCoverKind.video,
};

/// Renders a decoded cover at its intrinsic ratio after reserving fallback space.
class _IntrinsicCoverImage extends StatefulWidget {
  const _IntrinsicCoverImage({required this.bytes, required this.fallbackAspectRatio, required this.placeholder, required this.label});

  final Uint8List bytes;
  final double fallbackAspectRatio;
  final Widget placeholder;
  final String label;

  @override
  State<_IntrinsicCoverImage> createState() => _IntrinsicCoverImageState();
}

class _IntrinsicCoverImageState extends State<_IntrinsicCoverImage> {
  double? _aspectRatio;

  @override
  void initState() {
    super.initState();
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant _IntrinsicCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) {
      _aspectRatio = null;
      _resolveImage();
    }
  }

  Future<void> _resolveImage() async {
    final bytes = widget.bytes;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final aspectRatio = descriptor.width / descriptor.height;
      if (mounted && identical(bytes, widget.bytes) && _aspectRatio != aspectRatio) {
        setState(() => _aspectRatio = aspectRatio);
      }
    } catch (_) {
      // AppCoverImage owns the decode-failure presentation.
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final aspectRatio = _aspectRatio ?? 1 / widget.fallbackAspectRatio;
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: AppCoverImage(image: MemoryImage(widget.bytes), label: widget.label, placeholder: widget.placeholder),
    );
  }
}

DiscoveryCoverPresentation discoveryCoverPresentation(PluginCoverOrientation orientation) => switch (orientation) {
  PluginCoverOrientation.portrait => DiscoveryCoverPresentation.portrait,
  PluginCoverOrientation.square => DiscoveryCoverPresentation.square,
  PluginCoverOrientation.landscape => DiscoveryCoverPresentation.landscape,
};
