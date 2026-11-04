import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/reader/data/local_comic_image_bytes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('raster PNG bytes are returned unchanged', () async {
    final original = await _png(width: 3, height: 2);
    final prepared = await prepareLocalComicImageBytes(original, mimeType: 'image/png');
    expect(identical(prepared, original), isTrue);
    expect(prepared, original);
  });

  test('real SVG bytes rasterize to a PNG with intrinsic dimensions', () async {
    final svg = Uint8List.fromList(
      '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60" viewBox="0 0 120 60">'
              '<rect width="120" height="60" fill="#2878d0"/></svg>'
          .codeUnits,
    );
    final png = await prepareLocalComicImageBytes(svg, mimeType: 'image/svg+xml');
    final decoded = await _decodePngSize(png);
    expect(decoded, (width: 120, height: 60));
    expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
  });

  test('large SVG output stays within edge and pixel caps', () async {
    final svg = Uint8List.fromList(
      '<svg xmlns="http://www.w3.org/2000/svg" width="10000" height="10000" viewBox="0 0 10000 10000">'
              '<rect width="10000" height="10000" fill="#34a853"/></svg>'
          .codeUnits,
    );
    final png = await prepareLocalComicImageBytes(svg, mimeType: 'image/svg+xml');
    final size = await _decodePngSize(png);
    expect(size.width, lessThanOrEqualTo(4096));
    expect(size.height, lessThanOrEqualTo(4096));
    expect(size.width * size.height, lessThanOrEqualTo(4 * 1024 * 1024));
  });

  test('invalid SVG returns a readable format error', () async {
    final svg = Uint8List.fromList('<svg xmlns="http://www.w3.org/2000/svg" width="0" height="10"></svg>'.codeUnits);
    await expectLater(
      prepareLocalComicImageBytes(svg, mimeType: 'image/svg+xml'),
      throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('positive intrinsic dimensions'))),
    );
  });
}

Future<Uint8List> _png({required int width, required int height}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), ui.Paint()..color = const ui.Color(0xffd04080));
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return Uint8List.view(data!.buffer, data.offsetInBytes, data.lengthInBytes);
  } finally {
    image?.dispose();
    picture.dispose();
  }
}

Future<({int width, int height})> _decodePngSize(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    try {
      return (width: frame.image.width, height: frame.image.height);
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}
