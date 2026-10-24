import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_shell.dart';

const bool _exportPreview = bool.fromEnvironment('LIBRARY_HOME_TOP_VISUAL_PREVIEW');

void main() {
  setUpAll(() async {
    final FontLoader miSans = FontLoader('packages/novel_reader_ui/MiSans')
      ..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'));
    final FontLoader materialIcons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait(<Future<void>>[miSans.load(), materialIcons.load()]);
  });

  testWidgets('composes the actual home header and reading cover cleanly into its solid page background', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: RepaintBoundary(
            key: const Key('library-home-composition-test-boundary'),
            child: LibraryHomeShell(data: LibraryHomeFixtures.preview, isRefreshing: false, onRefresh: () async {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    final Finder homeBoundaryFinder = find.byKey(const Key('library-home-composition-test-boundary'));
    final RenderRepaintBoundary boundary = tester.renderObject(homeBoundaryFinder);
    final Rect homeBounds = tester.getRect(homeBoundaryFinder);
    final Rect backdropBounds = tester.getRect(find.byKey(const Key('library-home-top-backdrop')));
    final Rect coverBounds = tester.getRect(find.byKey(const Key('continue-reading-flat-cover')));
    final Color pageBackground = AppThemeTokens.of(tester.element(homeBoundaryFinder)).pageBackground;
    final Offset boundaryOrigin = boundary.localToGlobal(Offset.zero);
    final int backdropBottom = (backdropBounds.bottom - boundaryOrigin.dy).round();
    final int fadeOutStart = (backdropBounds.top - boundaryOrigin.dy + backdropBounds.height * 0.97).ceil();
    final int sampleEnd = backdropBottom + 10;
    late final ui.Image image;
    late final ByteData pixels;
    await tester.runAsync(() async {
      image = await boundary.toImage(pixelRatio: 1);
      pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      if (_exportPreview) {
        final Directory outputDirectory = Directory('.dart_tool/ai-checks');
        await outputDirectory.create(recursive: true);
        final ByteData png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('${outputDirectory.path}/library_home_composition_test.png').writeAsBytes(png.buffer.asUint8List());

        const int verticalScale = 8;
        final int cropTop = fadeOutStart.clamp(0, image.height - 1);
        final int cropBottom = sampleEnd.clamp(cropTop + 1, image.height);
        final int cropHeight = cropBottom - cropTop;
        final ui.PictureRecorder recorder = ui.PictureRecorder();
        final ui.Canvas canvas = ui.Canvas(recorder)..scale(1, verticalScale.toDouble());
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, cropTop.toDouble(), image.width.toDouble(), cropHeight.toDouble()),
          Rect.fromLTWH(0, 0, image.width.toDouble(), cropHeight.toDouble()),
          ui.Paint()..filterQuality = ui.FilterQuality.none,
        );
        final ui.Image seamStrip = await recorder.endRecording().toImage(image.width, cropHeight * verticalScale);
        final ByteData seamPng = (await seamStrip.toByteData(format: ui.ImageByteFormat.png))!;
        await File('${outputDirectory.path}/library_home_seam_pixel_strip.png').writeAsBytes(seamPng.buffer.asUint8List());
        seamStrip.dispose();
      }
    });
    addTearDown(image.dispose);

    final int coverX = (coverBounds.center.dx - homeBounds.left).round().clamp(0, image.width - 1);
    final int coverY = (coverBounds.center.dy - homeBounds.top).round().clamp(0, image.height - 1);
    final Color coverPixel = _pixelColor(pixels, image.width, coverX, coverY);
    int maximumSeamColorDelta = 0;
    for (int y = fadeOutStart; y < sampleEnd; y++) {
      for (int x = 0; x < image.width; x++) {
        final Color pixel = _pixelColor(pixels, image.width, x, y);
        maximumSeamColorDelta = <int>[
          maximumSeamColorDelta,
          (pixel.red - pageBackground.red).abs(),
          (pixel.green - pageBackground.green).abs(),
          (pixel.blue - pageBackground.blue).abs(),
          (pixel.alpha - pageBackground.alpha).abs(),
        ].reduce((int left, int right) => left > right ? left : right);
      }
    }
    if (_exportPreview) {
      print('HOME_SEAM_SCAN backdropBottom=$backdropBottom scannedRows=$fadeOutStart-${sampleEnd - 1} maxRGBDelta=$maximumSeamColorDelta');
    }

    expect(find.byType(LibraryHomeShell), findsOneWidget);
    expect(find.byKey(const Key('continue-reading-surface')), findsOneWidget);
    expect(image.width, 390);
    expect(image.height, 844);
    expect(coverPixel, isNot(pageBackground), reason: 'The actual last-read image should be present in the reading card.');
    expect(
      maximumSeamColorDelta,
      0,
      reason: 'Backdrop/page seam at row $backdropBottom differs from the page background by up to $maximumSeamColorDelta RGB units.',
    );
  });
}

Color _pixelColor(ByteData pixels, int width, int x, int y) {
  final int offset = (y * width + x) * 4;
  return Color.fromARGB(pixels.getUint8(offset + 3), pixels.getUint8(offset), pixels.getUint8(offset + 1), pixels.getUint8(offset + 2));
}
