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
/// TODO:
/// - 无。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/shared/presentation/widgets/default_book_cover_artwork.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

/// 显示不阻塞周边内容的数据源封面。
class DiscoveryBookCover extends ConsumerWidget {
  const DiscoveryBookCover({
    required this.title,
    required this.variant,
    required this.width,
    required this.height,
    this.coverBytes,
    this.remoteContentId,
    this.coverUrl,
    super.key,
  });

  final String title;
  final DiscoveryCoverVariant variant;
  final double width;
  final double height;
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
              borderRadius: AppRadii.discoveryCover,
              boxShadow: <BoxShadow>[
                BoxShadow(color: tokens.shadow, blurRadius: width >= 80 ? 8 : 3, offset: Offset(0, width >= 80 ? 4 : 1.5)),
              ],
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: <Color>[start, end]),
            ),
            child: ClipRRect(
              borderRadius: AppRadii.discoveryCover,
              child: !hasCoverBytes
                  ? _placeholder(foreground, start, end, isLoading: isLoading)
                  : Image.memory(
                      Uint8List.fromList(bytes!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _placeholder(foreground, start, end, isLoading: false),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholder(Color foreground, Color start, Color end, {required bool isLoading}) {
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
          borderRadius: AppRadii.discoveryCover,
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
}
