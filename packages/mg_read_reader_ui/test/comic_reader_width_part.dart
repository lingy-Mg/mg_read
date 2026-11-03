/// Comic width preferences, tablet layout and semantic anchor regression tests.
part of 'comic_reader_test.dart';

void _registerComicWidthTests() {
  test('comic width defaults to full width and normalizes invalid values', () {
    expect(ComicReaderPreferences.defaults.contentWidthFraction, 1);
    for (final value in <double>[double.nan, double.infinity]) {
      expect(
        ComicReaderPreferences(
          contentWidthFraction: value,
        ).normalized().contentWidthFraction,
        1,
      );
    }
    expect(
      const ComicReaderPreferences(
        contentWidthFraction: 0,
      ).normalized().contentWidthFraction,
      .1,
    );
    expect(
      const ComicReaderPreferences(
        contentWidthFraction: 2,
      ).normalized().contentWidthFraction,
      1,
    );
    final preferences = ComicReaderPreferences.defaults.copyWith(
      contentWidthFraction: .65,
    );
    expect(preferences.normalized().contentWidthFraction, .65);
    expect(preferences, isNot(ComicReaderPreferences.defaults));
    expect(preferences.copyWith(), preferences);
    expect(preferences.copyWith().hashCode, preferences.hashCode);
  });

  testWidgets(
    'tablet comic width updates, persists and retains the reading anchor',
    (tester) async {
      tester.view
        ..physicalSize = const Size(1200, 900)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = _MemoryComicStateStore(
        progress: const ComicReaderProgress(
          chapterId: 'chapter-1',
          imageId: 'image-5',
          imageFraction: .4,
        ),
      );
      final controller = ComicReaderController();
      addTearDown(controller.dispose);
      final source = _LongComicSource();
      Widget reader(Key key) => MaterialApp(
        home: ComicReaderView(
          key: key,
          bookId: 'book',
          dataSource: source,
          stateStore: store,
          controller: controller,
        ),
      );
      Finder image() => find.byType(ComicProgressiveImageTile).first;
      await tester.pumpWidget(reader(const ValueKey('first-session')));
      await tester.pumpAndSettle();
      expect(tester.getSize(image()).width, 1200);
      await tester.drag(
        find.byKey(const ValueKey<String>('comic-reader-content-surface')),
        const Offset(0, -1800),
      );
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(600, 450));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('comic-reader-settings')),
      );
      await tester.pumpAndSettle();
      final anchoredImage = find.byWidgetPredicate(
        (widget) =>
            widget is ComicProgressiveImageTile &&
            tester
                .getRect(find.byWidget(widget))
                .contains(const Offset(600, 306)),
      );
      final anchorId = tester
          .widget<ComicProgressiveImageTile>(anchoredImage)
          .image
          .id;
      final anchorRect = tester.getRect(anchoredImage);
      final anchorFraction = (306 - anchorRect.top) / anchorRect.height;
      expect(find.text('漫画宽度'), findsOneWidget);
      expect(find.text('100%（不限制）'), findsOneWidget);
      final slider = find.byKey(
        const ValueKey<String>('comic-reader-content-width'),
      );
      await tester.tapAt(tester.getCenter(slider));
      await tester.pumpAndSettle();
      final fraction = store.preferences!.contentWidthFraction;
      expect(fraction, closeTo(.55, .01));
      final rect = tester.getRect(image());
      expect(rect.width, closeTo(1200 * fraction, .1));
      expect(rect.center.dx, closeTo(600, .1));
      expect(rect.height, closeTo(rect.width, .1));
      expect(controller.snapshot.progress!.imageId, anchorId);
      expect(
        controller.snapshot.progress!.imageFraction,
        closeTo(anchorFraction, .01),
      );

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      // A new session loads the host-saved width rather than a view-local value.
      await tester.pumpWidget(reader(const ValueKey('second-session')));
      await tester.pumpAndSettle();
      expect(tester.getSize(image()).width, closeTo(1200 * fraction, .1));
      tester.view.physicalSize = const Size(900, 1200);
      await tester.pumpAndSettle();
      expect(tester.getSize(image()).width, closeTo(900 * fraction, .1));
      expect(tester.getRect(image()).center.dx, closeTo(450, .1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
