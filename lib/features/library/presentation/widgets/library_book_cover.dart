import 'package:flutter/material.dart';

import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';

/// A neutral, locally drawn book-cover representation with no remote assets.
class LibraryBookCover extends StatelessWidget {
  /// Creates a themed cover placeholder for [title].
  const LibraryBookCover({
    required this.title,
    required this.variant,
    required this.width,
    required this.height,
    super.key,
  });

  final String title;
  final LibraryCoverVariant variant;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final (Color start, Color end) = _gradientFor(tokens);

    return Semantics(
      image: true,
      label: AppStrings.bookCoverLabel(title),
      child: ExcludeSemantics(
        child: SizedBox(
          width: width,
          height: height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: AppRadii.control,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: tokens.shadow,
                  blurRadius: AppSpacing.regular,
                  offset: const Offset(0, AppSpacing.unit),
                ),
              ],
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[start, end],
              ),
            ),
            child: ClipRRect(
              borderRadius: AppRadii.control,
              child: Stack(
                children: <Widget>[
                  Align(
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.auto_stories_rounded,
                      color: tokens.featureSurface.withValues(alpha: 0.84),
                      size: AppSpacing.section + AppSpacing.compact,
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.regular),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: AppRadii.pill,
                          color: tokens.surface.withValues(alpha: 0.56),
                        ),
                        child: const SizedBox(
                          height: AppSpacing.compact,
                          width: AppSpacing.section,
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
