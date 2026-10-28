/// 真实阅读路由不能继承其他页面仍在显示或排队的底部错误提示。
part of 'reader_entry_transition_test.dart';

void _registerReaderSnackBarIsolation() {
  for (final comic in <bool>[false, true]) {
    testWidgets('reader isolates inherited and late shelf errors (comic=$comic)', (tester) async {
      _recordReaderSystemUi();
      final rootMessenger = GlobalKey<ScaffoldMessengerState>();
      final request = comic ? _comicRequest() : _request(dataSource: const _ImmediateDataSource());
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          scaffoldMessengerKey: rootMessenger,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => ReaderEntryTransition(request: request))),
                child: const Text('打开阅读'),
              ),
            ),
          ),
        ),
      );
      rootMessenger.currentState!.showSnackBar(
        SnackBar(
          content: const Text('旧阅读加载错误'),
          action: SnackBarAction(label: '重试', onPressed: () {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('旧阅读加载错误'), findsOneWidget);
      await tester.tap(find.text('打开阅读'));
      await _pumpReader(tester);
      await tester.pumpAndSettle();
      expect(find.byType(comic ? ComicReaderView : TextReaderView), findsOneWidget);
      expect(find.text('旧阅读加载错误'), findsNothing);

      rootMessenger.currentState!
        ..removeCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('后台迟到错误')));
      await tester.pumpAndSettle();
      expect(find.text('后台迟到错误'), findsNothing);

      final readerContext = tester.element(find.byType(ReaderHostPage));
      Navigator.of(readerContext).pop();
      await tester.pumpAndSettle();
      expect(find.text('打开阅读'), findsOneWidget);
      expect(find.text('后台迟到错误'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}
