import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/shared/presentation/widgets/default_book_cover_artwork.dart';

/// Displays a source-provided cover with a locally drawn fallback.
class DiscoveryBookCover extends StatelessWidget {
  const DiscoveryBookCover({
    required this.title,
    required this.variant,
    required this.width,
    required this.height,
    this.coverBytes,
    super.key,
  });

  final String title;
  final DiscoveryCoverVariant variant;
  final double width;
  final double height;
  final List<int>? coverBytes;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final (Color start, Color end) = _gradient(tokens);
    final bool hasCoverBytes = coverBytes?.isNotEmpty ?? false;
    final Color foreground = tokens.surface;
    return Semantics(
      image: true,
      label: hasCoverBytes ? '$title 的封面' : '$title 的封面占位图',
      child: ExcludeSemantics(
        child: SizedBox(
          width: width,
          height: height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: AppRadii.discoveryCover,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: tokens.shadow,
                  blurRadius: width >= 80 ? 8 : 3,
                  offset: Offset(0, width >= 80 ? 4 : 1.5),
                ),
              ],
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[start, end],
              ),
            ),
            child: ClipRRect(
              borderRadius: AppRadii.discoveryCover,
              child: !hasCoverBytes
                  ? _placeholder(foreground, start, end)
                  : Image.memory(
                      Uint8List.fromList(coverBytes!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          _placeholder(foreground, start, end),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholder(Color foreground, Color start, Color end) {
    return DefaultBookCoverArtwork(
      title: title,
      width: width,
      height: height,
      startColor: start,
      endColor: end,
      foregroundColor: foreground,
      borderRadius: AppRadii.discoveryCover,
    );
  }

  (Color, Color) _gradient(AppThemeTokens tokens) {
    return switch (variant) {
      DiscoveryCoverVariant.gothic => (
        tokens.coverDuskStart,
        tokens.coverDuskEnd,
      ),
      DiscoveryCoverVariant.dawn => (
        tokens.coverDawnStart,
        tokens.coverDawnEnd,
      ),
      DiscoveryCoverVariant.indigo => (
        tokens.coverIndigoEnd,
        tokens.coverOceanStart,
      ),
      DiscoveryCoverVariant.ember => (
        tokens.coverEmberEnd,
        tokens.coverEmberStart,
      ),
      DiscoveryCoverVariant.snow => (
        tokens.featureSurface,
        tokens.coverDawnEnd,
      ),
      DiscoveryCoverVariant.abyss => (
        tokens.coverOceanStart,
        tokens.coverIndigoStart,
      ),
    };
  }
}
