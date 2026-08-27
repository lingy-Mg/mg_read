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
/// TODO:
/// - 无。
library;

import 'dart:typed_data';

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
    super.key,
  });

  final String title;
  final LibraryCoverVariant variant;
  final double width;
  final double height;
  final String? assetPath;
  final List<int>? coverBytes;
  final BookCoverRequest? coverRequest;

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
    final isLoading = (bytes?.isNotEmpty ?? false) == false && asyncBytes?.isLoading == true;

    return Semantics(
      image: true,
      label: isLoading ? '$title 的封面加载中' : '$title 的封面',
      child: ExcludeSemantics(
        child: SizedBox(
          width: width,
          height: height,
          child: bytes != null && bytes.isNotEmpty
              ? ClipRRect(
                  borderRadius: AppRadii.bookCover,
                  child: Image.memory(
                    Uint8List.fromList(bytes),
                    width: width,
                    height: height,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stackTrace) => _placeholder(tokens, start, end, isLoading: false),
                  ),
                )
              : assetPath == null
              ? _placeholder(tokens, start, end, isLoading: isLoading)
              : ClipRRect(
                  borderRadius: AppRadii.bookCover,
                  child: Image.asset(
                    assetPath!,
                    width: width,
                    height: height,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => _placeholder(tokens, start, end, isLoading: false),
                  ),
                ),
        ),
      ),
    );
  }

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
