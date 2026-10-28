/// Profile golden assets must finish decoding before accepting pixels.
/// This helper only waits for images already rendered by local test fixtures;
/// it does not launch the app or access real profile data.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> settleProfileGoldenAssets(WidgetTester tester) async {
  final context = tester.element(find.byType(MaterialApp));
  final providers = tester.widgetList<Image>(find.byType(Image)).map((image) => image.image).toSet();
  await tester.runAsync(() async {
    for (final provider in providers) {
      await precacheImage(provider, context);
    }
  });
  await tester.pumpAndSettle();
  for (final image in tester.widgetList<RawImage>(find.byType(RawImage))) {
    expect(image.image, isNotNull, reason: 'A profile golden must not accept an undecoded image.');
  }
}
