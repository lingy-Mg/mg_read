/// Default-cover text remains legible even on the brightest caller palette.
/// Uses only local painting and checks rendered text/plate geometry and color.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/widgets/default_content_cover_artwork.dart';

void main() {
  for (final kind in DefaultCoverKind.values) {
    testWidgets('white artwork keeps ${kind.name} type and title legible', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                key: const Key('cover-boundary'),
                width: 168,
                height: 248,
                child: DefaultContentCoverArtwork(
                  kind: kind,
                  title: '很长的默认封面标题与内容',
                  width: 168,
                  height: 248,
                  startColor: Colors.white,
                  endColor: Colors.white,
                  foregroundColor: Colors.white,
                  borderRadius: AppRadii.bookCover,
                ),
              ),
            ),
          ),
        ),
      );
      for (final (textKey, plateKey) in [
        (ValueKey<String>('default-cover-label-${kind.name}'), ValueKey<String>('default-cover-label-plate-${kind.name}')),
        (const Key('default-cover-title'), const Key('default-cover-title-plate')),
      ]) {
        final text = tester.widget<Text>(find.byKey(textKey));
        final plate = tester.widget<DecoratedBox>(find.descendant(of: find.byKey(plateKey), matching: find.byType(DecoratedBox)));
        final background = Color.alphaBlend((plate.decoration as BoxDecoration).color!, Colors.white);
        final a = text.style!.color!.computeLuminance(), b = background.computeLuminance();
        final contrast = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
        expect(contrast, greaterThanOrEqualTo(4.5));
        expect(tester.getRect(find.byKey(const Key('cover-boundary'))).contains(tester.getRect(find.byKey(textKey)).bottomRight), isTrue);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
