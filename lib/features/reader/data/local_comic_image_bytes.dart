/// Normalizes parser-owned EPUB comic page resources for the raster-only
/// comic reader. Raster bytes pass through; sanitized SVG bytes are rendered
/// in memory without paths, network access, or persistent cache ownership.
library;

import 'package:mg_read/core/content_limits.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_svg/flutter_svg.dart';

const int _maxSvgBytes = ContentLimits.imageBytes;
const int _maxRasterEdge = 4096;
const int _maxRasterPixels = 4 * 1024 * 1024;

/// Returns raster bytes unchanged, or rasterizes an SVG MIME resource as PNG.
///
/// The caller must pass MIME metadata from the owned EPUB resource catalog.
/// SVG dimensions must be finite and positive. SVG input and output allocation
/// are bounded; malformed SVGs fail with a readable [FormatException].
Future<Uint8List> prepareLocalComicImageBytes(Uint8List bytes, {required String? mimeType}) async {
  final normalizedMime = mimeType?.split(';').first.trim().toLowerCase();
  if (normalizedMime != 'image/svg+xml') return bytes;
  if (bytes.isEmpty) throw const FormatException('Local EPUB SVG is empty.');
  if (bytes.length > _maxSvgBytes) {
    throw const FormatException('Local EPUB SVG exceeds the shared 100 MiB image budget.');
  }

  PictureInfo? pictureInfo;
  ui.Picture? outputPicture;
  ui.Image? image;
  try {
    pictureInfo = await vg.loadPicture(SvgBytesLoader(bytes), null);
    final size = pictureInfo.size;
    final sourceWidth = size.width;
    final sourceHeight = size.height;
    if (!sourceWidth.isFinite || !sourceHeight.isFinite || sourceWidth <= 0 || sourceHeight <= 0) {
      throw const FormatException('Local EPUB SVG must have finite positive intrinsic dimensions.');
    }

    final scale = math.min(
      1.0,
      math.min(
        _maxRasterEdge / math.max(sourceWidth, sourceHeight),
        math.sqrt(_maxRasterPixels) / math.sqrt(sourceWidth) / math.sqrt(sourceHeight),
      ),
    );
    final width = math.max(1, (sourceWidth * scale).floor());
    final height = math.max(1, (sourceHeight * scale).floor());
    if (width > _maxRasterEdge || height > _maxRasterEdge || width * height > _maxRasterPixels) {
      throw const FormatException('Local EPUB SVG exceeds the PNG raster limits.');
    }

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.scale(width / sourceWidth, height / sourceHeight);
    canvas.drawPicture(pictureInfo.picture);
    outputPicture = recorder.endRecording();
    image = await outputPicture.toImage(width, height);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null || png.lengthInBytes == 0) {
      throw const FormatException('Local EPUB SVG did not produce PNG bytes.');
    }
    return Uint8List.view(png.buffer, png.offsetInBytes, png.lengthInBytes);
  } on FormatException {
    rethrow;
  } on Object catch (error) {
    throw FormatException('Could not render local EPUB SVG: $error');
  } finally {
    image?.dispose();
    outputPicture?.dispose();
    pictureInfo?.picture.dispose();
  }
}
