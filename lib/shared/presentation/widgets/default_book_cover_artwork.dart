import 'package:flutter/material.dart';

/// A neutral, locally drawn book cover used when a source cover is unavailable.
///
/// It deliberately avoids genre-specific imagery so the same artwork works for
/// novels from discovery, search, detail, and the local shelf.
class DefaultBookCoverArtwork extends StatelessWidget {
  const DefaultBookCoverArtwork({
    required this.title,
    required this.width,
    required this.height,
    required this.startColor,
    required this.endColor,
    required this.foregroundColor,
    required this.borderRadius,
    super.key,
  });

  final String title;
  final double width;
  final double height;
  final Color startColor;
  final Color endColor;
  final Color foregroundColor;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final double titleSize = width >= 100
        ? width * 0.17
        : width >= 64
        ? width * 0.16
        : width * 0.145;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[startColor, endColor],
        ),
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Positioned(
              top: -width * 0.28,
              right: -width * 0.24,
              child: _orb(dimension: width * 0.96, opacity: 0.13),
            ),
            Positioned(
              bottom: height * 0.24,
              left: -width * 0.42,
              child: _orb(dimension: width * 0.86, opacity: 0.08),
            ),
            Positioned(
              top: width * 0.08,
              left: width * 0.08,
              right: width * 0.08,
              bottom: width * 0.08,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(width * 0.045),
                  border: Border.all(
                    color: foregroundColor.withValues(alpha: 0.18),
                  ),
                ),
              ),
            ),
            Align(
              alignment: const Alignment(0, -0.18),
              child: Transform.rotate(
                angle: -0.045,
                child: SizedBox(
                  width: width * 0.55,
                  height: height * 0.31,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: foregroundColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(width * 0.055),
                      border: Border.all(
                        color: foregroundColor.withValues(alpha: 0.34),
                      ),
                    ),
                    child: Stack(
                      children: <Widget>[
                        Positioned(
                          top: width * 0.06,
                          bottom: width * 0.06,
                          left: width * 0.1,
                          child: Container(
                            width: width * 0.028,
                            color: foregroundColor.withValues(alpha: 0.46),
                          ),
                        ),
                        Center(
                          child: Icon(
                            Icons.menu_book_rounded,
                            size: width * 0.31,
                            color: foregroundColor.withValues(alpha: 0.9),
                          ),
                        ),
                        Positioned(
                          left: width * 0.17,
                          right: width * 0.1,
                          bottom: width * 0.1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border(
                                top: BorderSide(
                                  color: foregroundColor.withValues(
                                    alpha: 0.38,
                                  ),
                                  width: 0.8,
                                ),
                              ),
                            ),
                            child: const SizedBox(height: 1),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
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
                      endColor.withValues(alpha: 0.84),
                    ],
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    width * 0.1,
                    height * 0.28,
                    width * 0.1,
                    width * 0.11,
                  ),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Text(
                      title,
                      maxLines: width >= 80 ? 2 : 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: foregroundColor,
                        fontSize: titleSize,
                        fontWeight: FontWeight.w600,
                        height: 1.08,
                        letterSpacing: width >= 80 ? 0.15 : 0,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _orb({required double dimension, required double opacity}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: foregroundColor.withValues(alpha: opacity),
        border: Border.all(color: foregroundColor.withValues(alpha: opacity)),
      ),
      child: SizedBox.square(dimension: dimension),
    );
  }
}
