import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';

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
    final Color foreground = variant == DiscoveryCoverVariant.snow
        ? const Color(0xFF33291F)
        : const Color(0xFFFDF8EF);
    final double titleSize = width >= 100
        ? 21
        : width >= 80
        ? 17
        : width >= 56
        ? 10.5
        : 7;

    return Semantics(
      image: true,
      label: coverBytes == null ? '$title 的封面占位图' : '$title 的封面',
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
              child: coverBytes == null || coverBytes!.isEmpty
                  ? _placeholder(foreground, titleSize)
                  : Image.memory(
                      Uint8List.fromList(coverBytes!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          _placeholder(foreground, titleSize),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholder(Color foreground, double titleSize) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned(
          top: -width * 0.18,
          right: -width * 0.22,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: foreground.withValues(alpha: 0.16),
              border: Border.all(color: foreground.withValues(alpha: 0.12)),
            ),
            child: SizedBox.square(dimension: width * 0.82),
          ),
        ),
        Positioned(
          left: width * 0.12,
          right: width * 0.12,
          top: height * 0.2,
          child: Divider(
            height: 1,
            thickness: 0.7,
            color: foreground.withValues(alpha: 0.24),
          ),
        ),
        Align(
          alignment: const Alignment(0, -0.2),
          child: Icon(
            _icon,
            size: width * (width >= 80 ? 0.44 : 0.4),
            color: foreground.withValues(alpha: 0.76),
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
                  Colors.black.withValues(
                    alpha: variant == DiscoveryCoverVariant.snow ? 0.18 : 0.48,
                  ),
                ],
              ),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                width * 0.08,
                height * 0.25,
                width * 0.08,
                width >= 80 ? 12 : 6,
              ),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Text(
                  title,
                  maxLines: width >= 80 ? 2 : 3,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: foreground,
                    fontSize: titleSize,
                    fontWeight: FontWeight.w600,
                    height: 1.05,
                    letterSpacing: width >= 80 ? 0.2 : 0,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
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

  IconData get _icon {
    return switch (variant) {
      DiscoveryCoverVariant.gothic => Icons.account_balance_rounded,
      DiscoveryCoverVariant.dawn => Icons.landscape_rounded,
      DiscoveryCoverVariant.indigo => Icons.auto_awesome_rounded,
      DiscoveryCoverVariant.ember => Icons.local_fire_department_rounded,
      DiscoveryCoverVariant.snow => Icons.terrain_rounded,
      DiscoveryCoverVariant.abyss => Icons.nightlight_round,
    };
  }
}
