import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';

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
      label: '$title 的封面占位图',
      child: ExcludeSemantics(
        child: SizedBox(
          width: width,
          height: height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: AppRadii.bookCover,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: tokens.shadow,
                  blurRadius: AppSpacing.unit,
                  offset: const Offset(0, AppSpacing.unit / 2),
                ),
              ],
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[start, end],
              ),
            ),
            child: ClipRRect(
              borderRadius: AppRadii.bookCover,
              child: Stack(
                children: <Widget>[
                  Positioned(
                    top: -width * 0.18,
                    right: -width * 0.12,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: tokens.featureSurface.withValues(alpha: 0.28),
                        shape: BoxShape.circle,
                      ),
                      child: SizedBox(
                        width: width * 0.68,
                        height: width * 0.68,
                      ),
                    ),
                  ),
                  Positioned(
                    top: height * 0.22,
                    left: width * 0.16,
                    right: width * 0.16,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            color: tokens.featureSurface.withValues(
                              alpha: 0.22,
                            ),
                          ),
                        ),
                      ),
                      child: const SizedBox(height: AppSpacing.unit),
                    ),
                  ),
                  Align(
                    alignment: const Alignment(0, -0.04),
                    child: Icon(
                      _coverIcon,
                      color: tokens.featureSurface.withValues(alpha: 0.84),
                      size: width * 0.36,
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: <Color>[
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.34),
                          ],
                        ),
                      ),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          width * 0.1,
                          height * 0.2,
                          width * 0.1,
                          width * 0.11,
                        ),
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: tokens.featureSurface.withValues(
                                  alpha: 0.96,
                                ),
                                fontSize: width * 0.16,
                                fontWeight: FontWeight.w600,
                                height: 1.1,
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

  IconData get _coverIcon {
    return switch (variant) {
      LibraryCoverVariant.dusk => Icons.account_balance_rounded,
      LibraryCoverVariant.dawn => Icons.landscape_rounded,
      LibraryCoverVariant.ocean => Icons.bolt_rounded,
      LibraryCoverVariant.indigo => Icons.nightlight_round,
      LibraryCoverVariant.ember => Icons.auto_awesome_rounded,
    };
  }
}
