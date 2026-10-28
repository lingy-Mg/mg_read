/// Headless evidence for production widgets, including dynamic clock values.
/// Captures the Flutter layer and overlays; never reads the user's desktop.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const visualEvidenceBoundaryKey = Key('visual-evidence-boundary');
bool _fontsLoaded = false;

Future<void> loadVisualEvidenceFonts() async {
  if (_fontsLoaded) return;
  await (FontLoader(
    'packages/novel_reader_ui/MiSans',
  )..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'))).load();
  await (FontLoader('MiSans')..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'))).load();
  // Native system fallbacks are absent in flutter_tester. Give the default
  // Material family the same local CJK fixture font for readable UI evidence.
  await (FontLoader('Roboto')..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'))).load();
  await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  _fontsLoaded = true;
}

Widget visualEvidenceHost(Widget child) => RepaintBoundary(key: visualEvidenceBoundaryKey, child: child);

Future<void> settleVisualEvidenceImages(WidgetTester tester) async {
  final context = tester.element(find.byType(MaterialApp));
  final providers = tester.widgetList<Image>(find.byType(Image)).map((image) => image.image).toSet();
  expect(providers, isNotEmpty, reason: 'This scene requires real decoded fixture artwork.');
  await tester.runAsync(() async {
    for (final provider in providers) {
      await precacheImage(provider, context);
    }
  });
  await tester.pumpAndSettle();
  final images = tester.widgetList<RawImage>(find.byType(RawImage));
  expect(images, isNotEmpty);
  for (final image in images) {
    expect(image.image, isNotNull, reason: 'Do not accept undecoded fixture artwork.');
  }
}

Future<void> captureVisualEvidence(WidgetTester tester, String name) async {
  await tester.pump();
  final renderError = tester.takeException();
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(visualEvidenceBoundaryKey));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File('artifacts/visual-audit-2026-10-28/supplemental/$name${renderError == null ? '' : '.failed'}.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
  });
  expect(renderError, isNull, reason: '$name must render without layout errors');
}
