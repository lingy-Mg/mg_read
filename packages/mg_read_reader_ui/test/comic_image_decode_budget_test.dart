import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:novel_reader_ui/src/ui/comic/comic_image_cache.dart';
import 'package:novel_reader_ui/src/ui/comic/comic_image_tile.dart';
import 'package:novel_reader_ui/src/ui/reader_theme.dart';

void main() {
  test(
    'decoded pixels remain bounded and allocation does not depend on arrival order',
    () {
      final owners = List<Object>.generate(3, (_) => Object());
      final desired = <int>[4096, 4096, 1024];
      final first = ComicDecodedImageBudget(maximumPixels: 6144);
      final reversed = ComicDecodedImageBudget(maximumPixels: 6144);
      for (var index = 0; index < owners.length; index++) {
        first.reserve(owners[index], desired[index]);
      }
      for (var index = owners.length - 1; index >= 0; index--) {
        reversed.reserve(owners[index], desired[index]);
      }
      final allocations = owners.map(first.allocationFor).toList();
      expect(allocations, owners.map(reversed.allocationFor));
      expect(allocations.every((pixels) => pixels > 1), isTrue);
      expect(
        allocations.reduce((left, right) => left + right),
        lessThanOrEqualTo(6144),
      );
      expect(first.reserve(owners.first, desired.first), allocations.first);
    },
  );

  testWidgets('decode pressure preserves image detail instead of a solid color', (
    tester,
  ) async {
    final source = _PatternSource(await _patternBytes(tester));
    final cache = ComicImageByteCache(bookId: 'book', dataSource: source);
    final budget = ComicDecodedImageBudget(maximumPixels: 4096);
    final other = Object();
    budget.reserve(other, 4096);
    await _mount(tester, cache, budget);
    await _waitForDecode(tester);

    expect(
      _decodedWidth(tester),
      greaterThan(1),
      reason: 'a 1px decode is stretched into an abnormal solid-color page',
    );
    final colors = await _sampleCorners(tester);
    expect(
      colors.$1,
      isNot(colors.$2),
      reason:
          'the red/blue page must retain visible detail before any menu interaction',
    );
    expect(source.calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    cache.dispose();
  });

  testWidgets(
    'released decode budget upgrades the image without a reader rebuild',
    (tester) async {
      final source = _PatternSource(await _patternBytes(tester));
      final cache = ComicImageByteCache(bookId: 'book', dataSource: source);
      final budget = ComicDecodedImageBudget(maximumPixels: 4096);
      final other = Object();
      budget.reserve(other, 4096);
      var parentBuilds = 0;
      await _mount(tester, cache, budget, onBuild: () => parentBuilds++);
      await _waitForDecode(tester);
      final before = _decodedWidth(tester);
      final builds = parentBuilds;

      budget.release(other);
      for (var frame = 0; frame < 40 && _decodedWidth(tester) != 64; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      expect(_decodedWidth(tester), 64);
      expect(_decodedWidth(tester), greaterThan(before));
      expect(
        parentBuilds,
        builds,
        reason:
            'opening the menu must not be required to refresh a decoded image',
      );
      expect(
        source.calls,
        1,
        reason:
            'resolution recovery reuses encoded bytes instead of downloading again',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      cache.dispose();
    },
  );

  testWidgets(
    'swapping budgets releases the old reservation and disposal drops pending notifications',
    (tester) async {
      final source = _PatternSource(await _patternBytes(tester));
      final cache = ComicImageByteCache(bookId: 'book', dataSource: source);
      final first = ComicDecodedImageBudget(maximumPixels: 4096);
      final second = ComicDecodedImageBudget(maximumPixels: 4096);
      final other = Object();
      first.reserve(other, 4096);
      await _mount(tester, cache, first);
      await _waitForDecode(tester);
      expect(first.allocationFor(other), lessThan(4096));
      await _mount(tester, cache, second);
      await _waitForDecode(tester, width: 64);
      expect(first.allocationFor(other), 4096);
      second.reserve(other, 4096);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(second.allocationFor(other), 4096);
      expect(tester.takeException(), isNull);
      expect(source.calls, 1);
      cache.dispose();
    },
  );
}

const _boundaryKey = ValueKey<String>('comic-image-pixel-probe');

Future<void> _mount(
  WidgetTester tester,
  ComicImageByteCache cache,
  ComicDecodedImageBudget budget, {
  VoidCallback? onBuild,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 64,
          height: 64,
          child: RepaintBoundary(
            key: _boundaryKey,
            child: Builder(
              builder: (context) {
                onBuild?.call();
                return ComicProgressiveImageTile(
                  cache: cache,
                  chapterId: 'chapter',
                  image: const ComicImageInfo(
                    id: 'image',
                    index: 0,
                    width: 64,
                    height: 64,
                  ),
                  width: 64,
                  placeholderHeight: 64,
                  palette: ReaderPalette.fromPreset(ReaderThemePreset.day),
                  onFailure: (error) =>
                      fail('Unexpected image failure: $error'),
                  decodeBudget: budget,
                );
              },
            ),
          ),
        ),
      ),
    ),
  ),
);

int _decodedWidth(WidgetTester tester) =>
    tester.widget<RawImage>(find.byType(RawImage)).image?.width ?? 0;

Future<void> _waitForDecode(WidgetTester tester, {int? width}) async {
  for (var frame = 0; frame < 40; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    if (find.byType(RawImage).evaluate().isNotEmpty &&
        _decodedWidth(tester) > 0 &&
        (width == null || _decodedWidth(tester) == width)) {
      return;
    }
  }
  fail('Image did not finish decoding');
}

Future<(int, int)> _sampleCorners(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(_boundaryKey),
      );
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final width = image.width;
      image.dispose();
      return (
        bytes.getUint32((8 * width + 8) * 4),
        bytes.getUint32((56 * width + 56) * 4),
      );
    }))!;

Future<Uint8List> _patternBytes(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(const Color(0xFFFF0000), BlendMode.src);
      canvas.drawRect(
        const Rect.fromLTWH(32, 32, 32, 32),
        Paint()..color = const Color(0xFF0000FF),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(64, 64);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
      return bytes;
    }))!;

class _PatternSource implements ComicReaderDataSource {
  _PatternSource(this.bytes);
  final Uint8List bytes;
  int calls = 0;
  @override
  Future<Uint8List> loadImageBytes(
    String bookId,
    String chapterId,
    String imageId,
  ) async {
    calls++;
    return bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
