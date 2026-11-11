/// Displays controlled local raster/SVG bytes without resolving external URLs.
/// EPUB SVGs are sanitized by the parser before reaching this widget.
/// Cover callers may supply decode placeholders and a semantic label; this widget performs no network requests.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

bool isLocalSvgImage(List<int> bytes) => utf8.decode(bytes.take(1024).toList(), allowMalformed: true).contains(RegExp(r'<svg(?:\s|>)'));

class LocalDocumentImage extends StatelessWidget {
  const LocalDocumentImage(
    this.bytes, {
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.fallback = const SizedBox.shrink(),
    this.loadingPlaceholder,
    this.semanticLabel,
    super.key,
  });
  final List<int> bytes;
  final double? width, height;
  final BoxFit fit;
  final Widget fallback;
  final Widget? loadingPlaceholder;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => isLocalSvgImage(bytes)
      ? SvgPicture.memory(
          Uint8List.fromList(bytes),
          width: width,
          height: height,
          fit: fit,
          semanticsLabel: semanticLabel,
          placeholderBuilder: loadingPlaceholder == null ? null : (_) => loadingPlaceholder!,
          errorBuilder: (_, _, _) => fallback,
        )
      : Image.memory(
          Uint8List.fromList(bytes),
          width: width,
          height: height,
          fit: fit,
          cacheWidth: 1024,
          errorBuilder: (_, _, _) => fallback,
        );
}
