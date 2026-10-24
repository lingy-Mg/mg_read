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
import 'package:mg_read/features/library/presentation/widgets/library_home_top_visual.dart';

const bool _exportPreview = bool.fromEnvironment('LIBRARY_HOME_TOP_VISUAL_PREVIEW');

void main() {
  testWidgets('fades the blurred last-read cover fully before its clipped bottom edge', (WidgetTester tester) async {
    final LibraryContinueReadingViewData fixture = LibraryHomeFixtures.preview.continueReading!;
    final ByteData coverData = await rootBundle.load(fixture.coverAssetPath!);
    final LibraryContinueReadingViewData data = LibraryContinueReadingViewData(
      bookId: fixture.bookId,
      title: fixture.title,
      chapter: fixture.chapter,
      progress: fixture.progress,
      lastReadLabel: fixture.lastReadLabel,
      coverVariant: fixture.coverVariant,
      coverBytes: coverData.buffer.asUint8List(coverData.offsetInBytes, coverData.lengthInBytes),
    );
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: CustomScrollView(
              slivers: <Widget>[
                SliverToBoxAdapter(
                  child: RepaintBoundary(
                    key: const Key('library-home-top-visual-test-boundary'),
                    child: LibraryHomeTopVisual(continueReading: data, child: const SizedBox(height: 320)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    final RenderRepaintBoundary boundary = tester.renderObject(find.byKey(const Key('library-home-top-visual-test-boundary')));
    late final ui.Image image;
    late final ByteData pixels;
    await tester.runAsync(() async {
      image = await boundary.toImage(pixelRatio: 1);
      pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      if (_exportPreview) {
        final Directory outputDirectory = Directory('.dart_tool/ai-checks');
        await outputDirectory.create(recursive: true);
        final ByteData png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('${outputDirectory.path}/library_home_top_visual_test.png').writeAsBytes(png.buffer.asUint8List());
      }
    });
    addTearDown(image.dispose);
    final int width = image.width;
    final int fadeOutStartRow = (image.height * 0.97).ceil();
    final List<int> fadeOutAlpha = <int>[
      for (int y = fadeOutStartRow; y < image.height; y++)
        for (int x = 0; x < width; x++) pixels.getUint8((y * width + x) * 4 + 3),
    ];
    final int visibleRowStart = (image.height - 12) * width * 4;
    final int visibleCenterAlpha = pixels.getUint8(visibleRowStart + (width ~/ 2) * 4 + 3);

    expect(image.height, 320);
    expect(visibleCenterAlpha, greaterThan(0), reason: 'The cover should remain visible above the fade-out region.');
    expect(
      fadeOutAlpha.every((int alpha) => alpha == 0),
      isTrue,
      reason: 'No cover pixels should survive in the final 3% before the clipped bottom edge.',
    );
  });
}
