/// 数据源内容的异步封面组件。
///
/// 职责：
/// - 先渲染书籍主体可见的加载占位，再独立解析封面字节。
/// - 复用共享请求键，避免相同封面在同一页面重复加载。
///
/// 注意：
/// - 加载或失败不得延迟父列表、发现页或详情页的首次显示。
/// - 无字节时保留默认封面插画作为可访问降级。
///
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/shared/presentation/widgets/default_book_cover_artwork.dart';
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
    final asyncBytes = request == null ? null : ref.watch(bookCoverBytesProvider(request));
    final List<int>? loadedBytes = switch (asyncBytes) {
      AsyncData<List<int>?>(:final value) => value,
      _ => null,
    };
    final bytes = coverBytes?.isNotEmpty ?? false ? coverBytes : loadedBytes;
    final bool hasCoverBytes = bytes?.isNotEmpty ?? false;
    final Uint8List? normalizedBytes = hasCoverBytes ? normalizeBookCoverBytes(bytes!) : null;
    final bool isLoading = !hasCoverBytes && asyncBytes?.isLoading == true;
    final Color foreground = tokens.surface;
    return Semantics(
      image: true,
      label: hasCoverBytes
          ? '$title 的封面'
          : isLoading
          ? '$title 的封面加载中'
          : '$title 的封面占位图',
      child: ExcludeSemantics(
        child: SizedBox(
          width: width,
          height: height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: _borderRadius,
              boxShadow: <BoxShadow>[
                BoxShadow(color: tokens.shadow, blurRadius: _visualWidth >= 80 ? 8 : 3, offset: Offset(0, _visualWidth >= 80 ? 4 : 1.5)),
              ],
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: <Color>[start, end]),
            ),
            child: ClipRRect(
              borderRadius: _borderRadius,
              child: !hasCoverBytes
                  ? SizedBox(
                      width: _placeholderWidth,
                      height: _placeholderHeight,
                      child: _placeholder(foreground, start, end, isLoading: isLoading),
                    )
                  : width == null || height == null
                  ? _IntrinsicCoverImage(
                      bytes: normalizedBytes!,
                      fallbackAspectRatio: _fallbackAspectRatio,
                      errorBuilder: (_, _, _) => SizedBox(
                        width: _placeholderWidth,
                        height: _placeholderHeight,
                        child: _placeholder(foreground, start, end, isLoading: false),
                      ),
                    )
                  : Image.memory(
                      normalizedBytes!,
                      width: width,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => SizedBox(
                        width: _placeholderWidth,
                        height: _placeholderHeight,
                        child: _placeholder(foreground, start, end, isLoading: false),
                      ),
                    ),
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

  Widget _placeholder(Color foreground, Color start, Color end, {required bool isLoading}) {
    if (presentation == DiscoveryCoverPresentation.landscape) {
      return _LandscapeCoverPlaceholder(foreground: foreground, start: start, end: end, width: _visualWidth, isLoading: isLoading);
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        DefaultBookCoverArtwork(
          title: title,
          width: _visualWidth,
          height: _placeholderHeight,
          startColor: start,
          endColor: end,
          foregroundColor: foreground,
          borderRadius: _borderRadius,
        ),
        if (isLoading)
          ColoredBox(
            color: Colors.black.withValues(alpha: 0.16),
            child: Center(
              child: SizedBox(
                width: _visualWidth >= 80 ? 22 : 16,
                height: _visualWidth >= 80 ? 22 : 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
              ),
            ),
          ),
      ],
    );
  }

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

/// Renders a decoded cover at its intrinsic ratio after reserving fallback space.
class _IntrinsicCoverImage extends StatefulWidget {
  const _IntrinsicCoverImage({required this.bytes, required this.fallbackAspectRatio, required this.errorBuilder});

  final Uint8List bytes;
  final double fallbackAspectRatio;
  final ImageErrorWidgetBuilder errorBuilder;

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
      // Image.memory renders the existing visual fallback for invalid bytes.
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
      child: Image.memory(widget.bytes, fit: BoxFit.cover, errorBuilder: widget.errorBuilder),
    );
  }
}

DiscoveryCoverPresentation discoveryCoverPresentation(PluginCoverOrientation orientation) => switch (orientation) {
  PluginCoverOrientation.portrait => DiscoveryCoverPresentation.portrait,
  PluginCoverOrientation.square => DiscoveryCoverPresentation.square,
  PluginCoverOrientation.landscape => DiscoveryCoverPresentation.landscape,
};

class _LandscapeCoverPlaceholder extends StatelessWidget {
  const _LandscapeCoverPlaceholder({
    required this.foreground,
    required this.start,
    required this.end,
    required this.width,
    required this.isLoading,
  });

  final Color foreground;
  final Color start;
  final Color end;
  final double width;
  final bool isLoading;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: <Widget>[
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[start.withValues(alpha: 0.88), end],
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: width >= 180 ? 18 : 12, vertical: width >= 180 ? 14 : 9),
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Icon(Icons.movie_rounded, size: width >= 180 ? 28 : 21, color: foreground.withValues(alpha: 0.86)),
          ),
        ),
      ),
      if (isLoading)
        ColoredBox(
          color: Colors.black.withValues(alpha: 0.14),
          child: Center(
            child: SizedBox(
              width: width >= 180 ? 22 : 16,
              height: width >= 180 ? 22 : 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
            ),
          ),
        ),
    ],
  );
}
