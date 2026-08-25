import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/shared/presentation/widgets/default_book_cover_artwork.dart';

/// A local book cover with a deterministic placeholder fallback.
class LibraryBookCover extends StatelessWidget {
  /// Creates a themed cover placeholder for [title].
  const LibraryBookCover({
    required this.title,
    required this.variant,
    required this.width,
    required this.height,
    this.assetPath,
    this.coverBytes,
    super.key,
  });

  final String title;
  final LibraryCoverVariant variant;
  final double width;
  final double height;
  final String? assetPath;
  final List<int>? coverBytes;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final (Color start, Color end) = _gradientFor(tokens);

    return Semantics(
      image: true,
      label: '$title 的封面',
      child: ExcludeSemantics(
        child: SizedBox(
          width: width,
          height: height,
          child: coverBytes != null && coverBytes!.isNotEmpty
              ? ClipRRect(
                  borderRadius: AppRadii.bookCover,
                  child: Image.memory(
                    Uint8List.fromList(coverBytes!),
                    width: width,
                    height: height,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        _placeholder(tokens, start, end),
                  ),
                )
              : assetPath == null
              ? _placeholder(tokens, start, end)
              : ClipRRect(
                  borderRadius: AppRadii.bookCover,
                  child: Image.asset(
                    assetPath!,
                    width: width,
                    height: height,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        _placeholder(tokens, start, end),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _placeholder(AppThemeTokens tokens, Color start, Color end) {
    return DefaultBookCoverArtwork(
      title: title,
      width: width,
      height: height,
      startColor: start,
      endColor: end,
      foregroundColor: tokens.featureSurface.withValues(alpha: 0.96),
      borderRadius: AppRadii.bookCover,
    );
  }

  (Color, Color) _gradientFor(AppThemeTokens tokens) {
    return switch (variant) {
      LibraryCoverVariant.dusk => (tokens.coverDuskStart, tokens.coverDuskEnd),
      LibraryCoverVariant.dawn => (tokens.coverDawnStart, tokens.coverDawnEnd),
      LibraryCoverVariant.ocean => (
        tokens.coverOceanStart,
        tokens.coverOceanEnd,
      ),
      LibraryCoverVariant.indigo => (
        tokens.coverIndigoStart,
        tokens.coverIndigoEnd,
      ),
      LibraryCoverVariant.ember => (
        tokens.coverEmberStart,
        tokens.coverEmberEnd,
      ),
    };
  }
}
