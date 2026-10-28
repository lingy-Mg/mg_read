/// 首屏就绪回归：等待可见封面解码，忽略屏外内容，失败和超时可退出。
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/library/presentation/widgets/library_first_frame.dart';

void main() {
  testWidgets('waits for both cover bytes and the decoded image frame', (tester) async {
    var ready = 0;
    final decoded = Completer<ImageInfo>();
    final provider = _DelayedImage(decoded.future);
    Widget host(bool loading) => _host(
      () => ready++,
      LibraryCoverFirstFrame(
        loading: loading,
        image: loading ? null : provider,
        child: SizedBox(width: 100, height: 150, child: loading ? null : Image(image: provider)),
      ),
    );
    await tester.pumpWidget(host(true));
    expect(ready, 0);
    await tester.pumpWidget(host(false));
    expect(ready, 0);
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
    final picture = recorder.endRecording();
    final image = await tester.runAsync(() => picture.toImage(2, 3));
    picture.dispose();
    decoded.complete(ImageInfo(image: image!));
    await tester.pump();
    await tester.pump();
    expect(ready, 1);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    await tester.pump(const Duration(seconds: 4));
    expect(ready, 1);
  });

  testWidgets('offscreen pending cover does not hold the first viewport', (tester) async {
    var ready = 0;
    await tester.pumpWidget(
      _host(
        () => ready++,
        const Stack(
          children: [
            Text('首屏内容'),
            Positioned(top: 1000, child: LibraryCoverFirstFrame(loading: true, image: null, child: SizedBox(width: 100, height: 150))),
          ],
        ),
      ),
    );
    expect(ready, 1);
  });

  testWidgets('intrinsic cover with a pending zero-height layout still holds the gate', (tester) async {
    var ready = 0;
    final provider = _DelayedImage(Completer<ImageInfo>().future);
    await tester.pumpWidget(
      _host(() => ready++, LibraryCoverFirstFrame(loading: false, image: provider, child: const SizedBox(width: 100, height: 0))),
    );
    expect(ready, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed cover uses its fallback without waiting for the deadline', (tester) async {
    var ready = 0;
    final decoded = Completer<ImageInfo>();
    final provider = _DelayedImage(decoded.future);
    await tester.pumpWidget(
      _host(
        () => ready++,
        LibraryCoverFirstFrame(
          loading: false,
          image: provider,
          child: SizedBox(
            width: 100,
            height: 150,
            child: Image(image: provider, errorBuilder: (_, error, stack) => const Text('默认封面')),
          ),
        ),
      ),
    );
    expect(ready, 0);
    decoded.completeError(StateError('cover unavailable'));
    await tester.pump();
    await tester.pump();
    expect(ready, 1);
    expect(find.text('默认封面'), findsOneWidget);
  });

  testWidgets('slow network is bounded and disposal cancels the deadline', (tester) async {
    var ready = 0;
    const pending = LibraryCoverFirstFrame(loading: true, image: null, child: SizedBox(width: 100, height: 150));
    await tester.pumpWidget(_host(() => ready++, pending));
    await tester.pump(const Duration(seconds: 2));
    expect(ready, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(ready, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_host(() => ready++, pending));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
    expect(ready, 1);
  });
}

Widget _host(VoidCallback onReady, Widget child) => MaterialApp(
  home: LibraryFirstFrame(
    onReady: onReady,
    child: Align(alignment: Alignment.topLeft, child: child),
  ),
);

class _DelayedImage extends ImageProvider<_DelayedImage> {
  _DelayedImage(this.decoded);
  final Future<ImageInfo> decoded;

  @override
  Future<_DelayedImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_DelayedImage key, ImageDecoderCallback decode) => OneFrameImageStreamCompleter(decoded);
}
