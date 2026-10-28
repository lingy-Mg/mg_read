/// Real reader entry/host/content/settings widgets with local fixture data.
/// Full PNG evidence retains the reader's live clock rather than masking it.
part of 'reader_entry_transition_test.dart';

void _registerReaderVisualEvidence() {
  for (final (name, size, preferences) in [
    ('day', const Size(390, 844), const TextReaderPreferences(keepScreenOn: false)),
    ('night-custom', const Size(390, 844), const TextReaderPreferences(theme: ReaderThemePreset.night, fontSize: 24, keepScreenOn: false)),
    (
      'wide-eyecare',
      const Size(1280, 900),
      const TextReaderPreferences(theme: ReaderThemePreset.eyeCare, fontSize: 24, keepScreenOn: false),
    ),
  ]) {
    testWidgets('production novel and settings visual evidence $name', (tester) async {
      _recordReaderSystemUi();
      final previousErrorHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exception.toString().contains('RenderFlex')) debugPrint(details.toString());
        previousErrorHandler?.call(details);
      };
      addTearDown(() => FlutterError.onError = previousErrorHandler);
      await loadVisualEvidenceFonts();
      _visualReaderViewport(tester, size);
      final request = NovelReaderLaunchRequest(
        bookId: 'visual-novel',
        dataSource: const _VisualTextDataSource(),
        stateStore: _VisualTextStore(preferences),
      );
      await tester.pumpWidget(visualEvidenceHost(_readerApp(request, appTheme: AppTheme.dark())));
      await _pumpReader(tester);
      expect(find.byType(TextReaderView), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('reader-content-surface')), findsOneWidget);
      await captureVisualEvidence(tester, 'novel-$name-content');
      await tester.tap(find.byKey(const ValueKey<String>('reader-content-surface')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reader-toolbar-settings')));
      await tester.pumpAndSettle();
      final sizeValue = tester.widget<Text>(
        find.descendant(of: find.byKey(const ValueKey<String>('reader-settings-font-size-value')), matching: find.byType(Text)),
      );
      expect(sizeValue.data, '${preferences.fontSize.round()}');
      await captureVisualEvidence(tester, 'novel-$name-settings');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
  testWidgets('production comic controls visual evidence', (tester) async {
    _recordReaderSystemUi();
    await loadVisualEvidenceFonts();
    _visualReaderViewport(tester, const Size(390, 844));
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 600, 900), Paint()..color = const Color(0xFFF4EFE6));
    for (final rect in [
      const Rect.fromLTWH(28, 70, 544, 330),
      const Rect.fromLTWH(28, 425, 260, 430),
      const Rect.fromLTWH(312, 425, 260, 430),
    ]) {
      canvas.drawRect(rect, Paint()..color = const Color(0xFF859CAC));
      canvas.drawRect(rect.deflate(8), Paint()..color = const Color(0xFFD8DFDD));
      canvas.drawCircle(rect.center, rect.shortestSide * .2, Paint()..color = const Color(0xFF526B7B));
    }
    final picture = recorder.endRecording();
    final bytes = await tester.runAsync(() async {
      final image = await picture.toImage(600, 900);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
      return bytes;
    });
    await tester.pumpWidget(visualEvidenceHost(_readerApp(_comicRequest(dataSource: _VisualComicDataSource(bytes!)))));
    await _pumpReader(tester);
    await tester.pumpAndSettle();
    expect(find.byType(ComicReaderView), findsOneWidget);
    await settleVisualEvidenceImages(tester);
    await tester.tap(find.byKey(const ValueKey<String>('comic-reader-content-surface')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('comic-reader-back-action')), findsOneWidget);
    await captureVisualEvidence(tester, 'comic-content-controls');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

void _visualReaderViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _VisualTextDataSource extends _ImmediateDataSource {
  const _VisualTextDataSource();
  @override
  Future<TextChapterContent> loadChapterContent(String bookId, String chapterId) async => TextChapterContent(
    chapterId: chapterId,
    title: '第一章 安静的书页',
    paragraphs: [
      for (var i = 0; i < 14; i++)
        TextParagraph(id: 'visual-$i', text: '清晨的光落在书页上，窗外传来轻轻的风声。阅读可以慢一些，让每一行文字都有舒适的留白。这里是用于检查真实排版与个性化设置的本地测试段落。'),
    ],
  );
}

class _VisualTextStore extends _StateStore {
  const _VisualTextStore(this.preferences);
  final TextReaderPreferences preferences;
  @override
  Future<TextReaderPreferences?> loadPreferences() async => preferences;
}

class _VisualComicDataSource extends _ImmediateComicDataSource {
  _VisualComicDataSource(this.bytes);
  final Uint8List bytes;
  @override
  Future<ComicChapterContent> loadChapterContent(String bookId, String chapterId) async => ComicChapterContent(
    chapterId: chapterId,
    title: '本地漫画测试页',
    images: [ComicImageInfo(id: 'visual-comic', index: 0, width: 600, height: 900)],
  );
  @override
  Future<Uint8List> loadImageBytes(String bookId, String chapterId, String imageId) async => bytes;
}
