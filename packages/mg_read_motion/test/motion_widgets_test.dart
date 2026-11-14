/// 共享无动画控件的行为回归：无持续帧、真实交互、焦点、语义及正常模式恢复。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_motion/mg_read_motion.dart';

void main() {
  testWidgets(
    'list selection and theme change have no text tween, with keyboard and long press retained',
    (tester) async {
      var selected = false;
      var longPresses = 0;
      final focus = FocusNode();
      addTearDown(focus.dispose);
      Widget content() => StatefulBuilder(
        builder: (context, setState) => MotionListTile(
          focusNode: focus,
          minTileHeight: 54,
          title: const Text('列表项'),
          subtitle: const Text('说明'),
          selected: selected,
          onTap: () => setState(() => selected = !selected),
          onLongPress: () => longPresses++,
        ),
      );
      await tester.pumpWidget(
        _host(MotionTheme(data: ThemeData.light(), child: content())),
      );
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(selected, isTrue);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.longPress(find.text('列表项'));
      await tester.pump();
      expect(longPresses, 1);
      await tester.pumpWidget(
        _host(MotionTheme(data: ThemeData.dark(), child: content())),
      );
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'segmented selection applies immediately without button transitions',
    (tester) async {
      var selected = 1;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('第一项')),
                ButtonSegment(value: 2, label: Text('第二项')),
              ],
              selected: {selected},
              onSelectionChanged: (values) =>
                  setState(() => selected = values.single),
            ),
          ),
        ),
      );
      await tester.tap(find.text('第二项'));
      await tester.pump();
      expect(selected, 2);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'native icon tooltip keeps its accessible name, focus and action in static mode',
    (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var actions = 0;
      Widget host(bool disabled) => _host(
        MotionIconButtonSurface(
          child: IconButton(
            key: const Key('named-action'),
            tooltip: '命名动作',
            focusNode: focus,
            onPressed: () => actions++,
            icon: const Icon(Icons.play_arrow),
          ),
        ),
        disabled: disabled,
      );
      await tester.pumpWidget(host(false));
      focus.requestFocus();
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(true));
      await tester.pump();
      expect(focus.hasPrimaryFocus, isTrue);
      expect(find.byTooltip('命名动作'), findsOneWidget);
      await tester.tap(find.byKey(const Key('named-action')));
      await tester.pump();
      expect(actions, 1);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'automatic app bar back action retains its tooltip semantics without motion',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: MotionTheme(
              data: ThemeData(),
              child: Builder(
                builder: (context) => MotionScaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      PageRouteBuilder<void>(
                        transitionDuration: Duration.zero,
                        reverseTransitionDuration: Duration.zero,
                        pageBuilder: (context, _, _) => MediaQuery(
                          data: const MediaQueryData(disableAnimations: true),
                          child: MotionScaffold(
                            appBar: MotionAppBarSurface(
                              child: AppBar(title: const Text('页面')),
                            ),
                            body: const Text('内容'),
                          ),
                        ),
                      ),
                    ),
                    child: const Text('打开'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final context = tester.element(find.text('页面'));
      final tooltip = MaterialLocalizations.of(context).backButtonTooltip;
      expect(find.byTooltip(tooltip), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.tap(find.byTooltip(tooltip));
      await tester.pumpAndSettle();
      expect(find.text('打开'), findsOneWidget);
    },
  );
  testWidgets(
    'choice chips commit selection without press or elevation animation',
    (tester) async {
      var selected = false;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (_, update) => MotionChoiceChip(
              label: const Text('筛选项'),
              selected: selected,
              onSelected: (value) => update(() => selected = value),
            ),
          ),
        ),
      );
      final press = await tester.startGesture(
        tester.getCenter(find.text('筛选项')),
      );
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.binding.transientCallbackCount, 0);
      await press.up();
      await tester.pump();
      expect(selected, isTrue);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets('snackbar action retains its callback and action close reason', (
    tester,
  ) async {
    late BuildContext content;
    var calls = 0;
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) {
            content = context;
            return const Text('页面');
          },
        ),
      ),
    );
    final notice = ScaffoldMessenger.of(content).showMotionSnackBar(
      content,
      SnackBar(
        content: const Text('失败'),
        action: SnackBarAction(label: '重试', onPressed: () => calls++),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(calls, 1);
    expect(await notice.closed, SnackBarClosedReason.action);
    expect(tester.binding.transientCallbackCount, 0);
  });
  setUpAll(() async {
    var repository = Directory.current;
    while (!Directory('${repository.path}/tools').existsSync() &&
        repository.parent.path != repository.path) {
      repository = repository.parent;
    }
    final bytes = File(
      '${repository.path}/packages/mg_read_reader_ui/assets/fonts/MiSansVF.ttf',
    ).readAsBytesSync();
    for (final family in ['Roboto', 'Segoe UI', 'MiSans']) {
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets('card policy changes retain text editing state and focus', (
    tester,
  ) async {
    final controller = TextEditingController(text: '保留');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    Widget host(bool disabled) => _host(
      SizedBox(
        width: 300,
        child: MotionCard(
          child: MotionTextField(controller: controller, focusNode: focus),
        ),
      ),
      disabled: disabled,
    );
    await tester.pumpWidget(host(false));
    focus.requestFocus();
    await tester.pumpAndSettle();
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    await tester.pumpWidget(host(true));
    await tester.pump();
    expect(
      identical(
        state,
        tester.state<EditableTextState>(find.byType(EditableText)),
      ),
      isTrue,
    );
    expect(focus.hasPrimaryFocus, isTrue);
    expect(controller.text, '保留');
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.binding.transientCallbackCount, 0);
  });
  testWidgets(
    'static controls and the focused caret remain pixel identical while idle',
    (tester) async {
      final surface = GlobalKey();
      final controller = TextEditingController(text: '电子墨水屏静态输入');
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        _host(
          RepaintBoundary(
            key: surface,
            child: SizedBox(
              width: 360,
              height: 460,
              child: ColoredBox(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      MotionTextField(
                        controller: controller,
                        focusNode: focus,
                        decoration: const InputDecoration(labelText: '静态光标'),
                      ),
                      const MotionSwitchListTile(
                        title: Text('无动画开关'),
                        value: true,
                        onChanged: _ignore,
                      ),
                      MotionCheckboxListTile(
                        title: const Text('静态复选'),
                        value: true,
                        onChanged: (_) {},
                      ),
                      MotionSlider(value: .6, onChanged: (_) {}),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          MotionCircularProgressIndicator(),
                          SizedBox(width: 12),
                          Text('正在加载'),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const MotionLinearProgressIndicator(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      focus.requestFocus();
      controller.selection = const TextSelection.collapsed(offset: 4);
      await tester.pumpAndSettle();
      Future<List<int>> snapshot() async => (await tester.runAsync(() async {
        final image =
            await (surface.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return data!.buffer.asUint8List();
      }))!;
      final before = await snapshot();
      await tester.pump(const Duration(seconds: 1));
      expect(await snapshot(), orderedEquals(before));
      expect(tester.binding.transientCallbackCount, 0);
      var repository = Directory.current;
      while (!Directory('${repository.path}/tools').existsSync() &&
          repository.parent.path != repository.path) {
        repository = repository.parent;
      }
      final evidence = File(
        '${repository.path}/.dart_tool/ai-checks/no-animation-static-controls.png',
      );
      evidence.parent.createSync(recursive: true);
      evidence.writeAsBytesSync(before);
    },
  );
  testWidgets(
    'focused text input keeps a static caret, selection and focus across policy changes',
    (tester) async {
      final controller = TextEditingController(text: '保留输入');
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      Widget host(bool disabled) => _host(
        SizedBox(
          width: 300,
          child: MotionTextField(
            controller: controller,
            focusNode: focus,
            decoration: const InputDecoration(labelText: '文本'),
          ),
        ),
        disabled: disabled,
      );
      await tester.pumpWidget(host(false));
      focus.requestFocus();
      await tester.pumpAndSettle();
      controller.selection = const TextSelection.collapsed(offset: 2);
      await tester.pump();
      final editor = tester.state<EditableTextState>(find.byType(EditableText));
      await tester.pumpWidget(host(true));
      await tester.pump();
      expect(
        identical(
          editor,
          tester.state<EditableTextState>(find.byType(EditableText)),
        ),
        isTrue,
      );
      expect(controller.selection.baseOffset, 2);
      expect(focus.hasPrimaryFocus, isTrue);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).showCursor,
        isFalse,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.enterText(find.byType(EditableText), '静态输入可编辑');
      await tester.pump();
      expect(controller.text, '静态输入可编辑');
      await tester.enterText(find.byType(EditableText), '长文本输入' * 40);
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .state<EditableTextState>(find.byType(EditableText))
            .renderEditable
            .offset
            .pixels,
        greaterThan(0),
      );
      await tester
          .pump(); // Flush the caret's scroll-metrics layout notification.
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .selectionControls!
            .getHandleSize(20),
        Size.zero,
      );
      await tester.pump(
        const Duration(milliseconds: 200),
      ); // Empty desktop handles have no painted transition.
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(host(false));
      await tester.pumpAndSettle();
      expect(
        identical(
          editor,
          tester.state<EditableTextState>(find.byType(EditableText)),
        ),
        isTrue,
      );
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).showCursor,
        isTrue,
      );
    },
  );

  testWidgets('static text form keeps validation and reset behavior', (
    tester,
  ) async {
    final form = GlobalKey<FormState>();
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 300,
          child: Form(
            key: form,
            child: MotionTextFormField(
              initialValue: '初始',
              decoration: const InputDecoration(labelText: '名称'),
              validator: (value) => value?.isNotEmpty == true ? null : '必填',
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(EditableText), '');
    await tester.pump();
    expect(form.currentState!.validate(), isFalse);
    await tester.pump();
    expect(find.text('必填'), findsOneWidget);
    form.currentState!.reset();
    await tester.pump();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      '初始',
    );
    expect(form.currentState!.validate(), isTrue);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
  });
  testWidgets(
    'unknown loaders become static while real progress remains accurate',
    (tester) async {
      await tester.pumpWidget(
        _host(
          const Column(
            children: [
              MotionCircularProgressIndicator(),
              MotionLinearProgressIndicator(),
              MotionLinearProgressIndicator(value: .37),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .37,
      );
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'changing policy stops a running loader and restores it when enabled',
    (tester) async {
      Widget host(bool disabled) =>
          _host(const MotionCircularProgressIndicator(), disabled: disabled);
      await tester.pumpWidget(host(false));
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(host(true));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(host(false));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'switch retains focus, semantics and keyboard operation without tickers',
    (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var value = false;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (_, update) => Semantics(
              label: '设置开关',
              child: MotionSwitch(
                value: value,
                focusNode: focus,
                onChanged: (next) => update(() => value = next),
              ),
            ),
          ),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(value, isTrue);
      expect(focus.hasPrimaryFocus, isTrue);
      expect(
        tester.getSemantics(find.bySemanticsLabel('设置开关')),
        matchesSemantics(
          label: '设置开关',
          hasEnabledState: true,
          isEnabled: true,
          hasToggledState: true,
          isToggled: true,
          isFocusable: true,
          isFocused: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      expect(tester.binding.transientCallbackCount, 0);
      await tester.tap(find.byType(MotionSwitch));
      await tester.pump();
      expect(value, isFalse);
      expect(focus.hasPrimaryFocus, isTrue);
    },
  );

  testWidgets(
    'checkbox supports three states and disabled tiles stay unchanged',
    (tester) async {
      bool? value = false;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (_, update) => Column(
              children: [
                MotionCheckboxListTile(
                  title: const Text('三态'),
                  value: value,
                  tristate: true,
                  onChanged: (next) => update(() => value = next),
                ),
                const MotionSwitchListTile(
                  title: Text('只读'),
                  value: true,
                  onChanged: null,
                ),
              ],
            ),
          ),
        ),
      );
      for (final next in <bool?>[true, null, false]) {
        await tester.tap(find.text('三态'));
        await tester.pump();
        expect(value, next);
        expect(tester.binding.transientCallbackCount, 0);
      }
      await tester.tap(find.text('只读'));
      await tester.pump();
      expect(
        tester
            .widget<MotionSwitchListTile>(find.byType(MotionSwitchListTile))
            .value,
        isTrue,
      );
    },
  );

  testWidgets('changing policy retains the focused setting and its value', (
    tester,
  ) async {
    Widget host(bool disabled) => _host(
      const MotionSwitchListTile(
        title: Text('选项'),
        value: true,
        onChanged: _ignore,
      ),
      disabled: disabled,
    );
    await tester.pumpWidget(host(false));
    final node = tester
        .widget<SwitchListTile>(find.byType(SwitchListTile))
        .focusNode!;
    node.requestFocus();
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(true));
    await tester.pump();
    expect(node.hasPrimaryFocus, isTrue);
    expect(
      tester
          .widget<MotionSwitchListTile>(find.byType(MotionSwitchListTile))
          .value,
      isTrue,
    );
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'pull refresh runs once with static feedback and no animation frames',
    (tester) async {
      final pending = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(
        _host(
          MotionRefreshIndicator(
            onRefresh: () {
              calls++;
              return pending.future;
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [SizedBox(height: 1000)],
            ),
          ),
        ),
      );
      await tester.drag(find.byType(ListView), const Offset(0, 350));
      await tester.pump();
      expect(calls, 1);
      expect(find.text('正在刷新…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.drag(find.byType(ListView), const Offset(0, 350));
      expect(calls, 1);
      pending.complete();
      await tester.pump();
      expect(find.text('正在刷新…'), findsNothing);
      expect(find.byType(RefreshProgressIndicator), findsNothing);
    },
  );

  testWidgets(
    'snackbar enters and exits instantly then normal animation returns',
    (tester) async {
      late BuildContext content;
      Widget host(bool disabled) => _host(
        Builder(
          builder: (context) {
            content = context;
            return const Text('页面');
          },
        ),
        disabled: disabled,
      );
      await tester.pumpWidget(host(true));
      ScaffoldMessenger.of(
        content,
      ).showMotionSnackBar(content, const SnackBar(content: Text('提示')));
      await tester.pump();
      expect(
        tester.widget<SnackBar>(find.byType(SnackBar)).animation!.value,
        1,
      );
      ScaffoldMessenger.of(content).hideCurrentSnackBar();
      await tester.pump();
      expect(find.text('提示'), findsNothing);
      await tester.pumpWidget(host(false));
      ScaffoldMessenger.of(
        content,
      ).showMotionSnackBar(content, const SnackBar(content: Text('提示')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        tester.widget<SnackBar>(find.byType(SnackBar)).animation!.value,
        inExclusiveRange(0, 1),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'changing policy while refreshing preserves one task and its waiting state',
    (tester) async {
      final pending = Completer<void>();
      var calls = 0;
      Widget host(bool disabled) => _host(
        MotionRefreshIndicator(
          onRefresh: () {
            calls++;
            return pending.future;
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: const [SizedBox(height: 1000)],
          ),
        ),
        disabled: disabled,
      );
      await tester.pumpWidget(host(false));
      unawaited(
        tester
            .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
            .show(),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(calls, 1);
      await tester.pumpWidget(host(true));
      await tester.pump();
      expect(find.text('正在刷新…'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.drag(find.byType(ListView), const Offset(0, 350));
      expect(calls, 1);
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.text('正在刷新…'), findsNothing);
    },
  );

  testWidgets('static slider preserves drag, keyboard and change boundaries', (
    tester,
  ) async {
    var value = 0.0;
    var starts = 0;
    var ends = 0;
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (_, update) => SizedBox(
            width: 400,
            child: MotionSlider(
              value: value,
              divisions: 10,
              focusNode: focus,
              onChangeStart: (_) => starts++,
              onChangeEnd: (_) => ends++,
              onChanged: (next) => update(() => value = next),
            ),
          ),
        ),
      ),
    );
    await tester.tapAt(tester.getCenter(find.byType(MotionSlider)));
    await tester.pump();
    expect(value, .5);
    expect(starts, 1);
    expect(ends, 1);
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(value, .6);
    expect(starts, 2);
    expect(ends, 2);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'dropdown menu opens instantly and preserves form validation and selection',
    (tester) async {
      var selected = 'a';
      var changes = 0;
      final form = GlobalKey<FormState>();
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (_, update) => SizedBox(
              width: 300,
              child: Form(
                key: form,
                child: MotionDropdownButtonFormField<String>(
                  initialValue: selected,
                  decoration: const InputDecoration(labelText: '选项'),
                  items: const [
                    DropdownMenuItem(value: 'a', child: Text('选项 A')),
                    DropdownMenuItem(value: 'b', child: Text('选项 B')),
                  ],
                  validator: (value) => value == 'b' ? null : '请选择 B',
                  onChanged: (next) {
                    changes++;
                    update(() => selected = next!);
                  },
                ),
              ),
            ),
          ),
        ),
      );
      expect(form.currentState!.validate(), isFalse);
      await tester.pumpAndSettle();
      await tester.tap(find.text('选项 A'));
      await tester.pump();
      expect(
        ModalRoute.of(tester.element(find.text('选项 B')))!.animation!.value,
        1,
      );
      await tester.tap(find.text('选项 B'));
      await tester.pump();
      expect(selected, 'b');
      expect(changes, 1);
      expect(form.currentState!.validate(), isTrue);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'disabling motion finishes a snackbar already entering and disables swipe motion',
    (tester) async {
      late BuildContext content;
      Widget host(bool disabled) => _host(
        Builder(
          builder: (context) {
            content = context;
            return const Text('页面');
          },
        ),
        disabled: disabled,
      );
      await tester.pumpWidget(host(false));
      ScaffoldMessenger.of(
        content,
      ).showMotionSnackBar(content, const SnackBar(content: Text('进行中')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        tester.widget<SnackBar>(find.byType(SnackBar)).animation!.value,
        inExclusiveRange(0, 1),
      );
      await tester.pumpWidget(host(true));
      await tester.pump();
      expect(
        tester.widget<SnackBar>(find.byType(SnackBar)).animation!.value,
        1,
      );
      expect(tester.binding.transientCallbackCount, 0);
      ScaffoldMessenger.of(content).hideCurrentSnackBar();
      await tester.pump();
      ScaffoldMessenger.of(
        content,
      ).showMotionSnackBar(content, const SnackBar(content: Text('静态提示')));
      await tester.pump();
      expect(
        tester.widget<SnackBar>(find.byType(SnackBar)).dismissDirection,
        DismissDirection.none,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'hover tooltip appears and disappears without a fade controller',
    (tester) async {
      await tester.pumpWidget(
        _host(
          const MotionTooltip(
            message: '完整提示',
            waitDuration: Duration.zero,
            child: Text('目标'),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(0, 0));
      await mouse.moveTo(tester.getCenter(find.text('目标')));
      await tester.pump();
      expect(find.text('完整提示'), findsOneWidget);
      await tester
          .pump(); // RawTooltip positions its overlay after the first layout.
      expect(tester.binding.hasScheduledFrame, isFalse);
      await mouse.moveTo(const Offset(0, 0));
      await tester.pump();
      expect(find.text('完整提示'), findsNothing);
      await mouse.removePointer();
    },
  );
}

void _ignore(bool value) {}

Widget _host(Widget child, {bool disabled = true}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(
      disableAnimations: disabled,
      size: const Size(800, 600),
    ),
    child: MotionTheme(
      data: ThemeData(),
      child: Scaffold(body: Center(child: child)),
    ),
  ),
);
