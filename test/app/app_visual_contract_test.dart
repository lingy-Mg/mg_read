/// 宿主公共控件的深浅色、窄屏和桌面渲染验收。
/// Golden 只表达 Flutter 布局与绘制，不代表系统窗口或 Android 设备验收。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'packages/novel_reader_ui/MiSans',
    )..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final dark in [false, true]) {
    for (final wide in [false, true]) {
      testWidgets('host controls ${dark ? 'dark' : 'light'} ${wide ? 'wide' : 'narrow'}', (tester) async {
        tester.view.physicalSize = Size(wide ? 1280 : 320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(debugShowCheckedModeBanner: false, theme: dark ? AppTheme.dark() : AppTheme.light(), home: const _Controls()),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/controls_${dark ? 'dark' : 'light'}_${wide ? 'wide' : 'narrow'}.png'),
        );

        await tester.tap(find.text('打开确认弹窗'));
        await tester.pumpAndSettle();
        final dialog = tester.getRect(find.descendant(of: find.byType(AlertDialog), matching: find.byType(Material)).first);
        expect(dialog.width, lessThanOrEqualTo(560));
        expect(dialog.left, greaterThanOrEqualTo(0));
        expect(dialog.right, lessThanOrEqualTo(wide ? 1280 : 320));
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/dialog_${dark ? 'dark' : 'light'}_${wide ? 'wide' : 'narrow'}.png'),
        );
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('打开操作面板'));
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.descendant(of: find.byType(BottomSheet), matching: find.byType(Material)).first).width,
          lessThanOrEqualTo(640),
        );
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/sheet_${dark ? 'dark' : 'light'}_${wide ? 'wide' : 'narrow'}.png'),
        );
      });
    }
  }
}

class _Controls extends StatelessWidget {
  const _Controls();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: AppSecondaryPageContent(
        child: Column(
          children: [
            AppSecondaryPageTopBar(title: '阅读偏好与管理', onBack: () {}),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.comfortable),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.comfortable),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text('舒适、清晰、一致', style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: AppSpacing.compact),
                            const Text('用统一的文字、间距和控件呈现阅读管理。'),
                            const SizedBox(height: AppSpacing.comfortable),
                            const TextField(
                              decoration: InputDecoration(labelText: '书籍名称', hintText: '输入书名或作者', prefixIcon: Icon(Icons.search_rounded)),
                            ),
                            const SizedBox(height: AppSpacing.comfortable),
                            Wrap(
                              spacing: AppSpacing.compact,
                              runSpacing: AppSpacing.compact,
                              children: [
                                ChoiceChip(label: const Text('全部'), selected: true, onSelected: (_) {}),
                                ChoiceChip(label: const Text('连载'), selected: false, onSelected: (_) {}),
                                const Chip(label: Text('已缓存')),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.comfortable),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.bookmark_outline),
                              title: const Text('保留阅读偏好'),
                              subtitle: const Text('阅读字体与背景由阅读器独立管理'),
                              trailing: Switch(value: true, onChanged: (_) {}),
                            ),
                            const SizedBox(height: AppSpacing.comfortable),
                            Wrap(
                              spacing: AppSpacing.compact,
                              runSpacing: AppSpacing.compact,
                              children: [
                                FilledButton(onPressed: () {}, child: const Text('继续阅读')),
                                OutlinedButton(onPressed: () {}, child: const Text('加入书架')),
                                const FilledButton(onPressed: null, child: Text('正在准备')),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.comfortable),
                            FilledButton(
                              onPressed: () => showDialog<void>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('移出书架'),
                                  content: const Text('确认移出所选书籍？此操作保留阅读器中的字体和背景偏好。'),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
                                    FilledButton(onPressed: () => Navigator.pop(context), child: const Text('确认')),
                                  ],
                                ),
                              ),
                              child: const Text('打开确认弹窗'),
                            ),
                            const SizedBox(height: AppSpacing.compact),
                            OutlinedButton(
                              onPressed: () => showModalBottomSheet<void>(
                                context: context,
                                showDragHandle: true,
                                builder: (context) => SafeArea(
                                  child: Padding(
                                    padding: const EdgeInsets.all(AppSpacing.comfortable),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                        Text('书籍操作', style: Theme.of(context).textTheme.titleLarge),
                                        ListTile(leading: const Icon(Icons.refresh_rounded), title: const Text('刷新详情'), onTap: () {}),
                                        ListTile(leading: const Icon(Icons.bookmark_outline), title: const Text('加入书架'), onTap: () {}),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              child: const Text('打开操作面板'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
