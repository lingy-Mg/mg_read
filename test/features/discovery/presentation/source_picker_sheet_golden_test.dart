import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/discovery_page.dart';
import 'package:mg_read/features/discovery/presentation/source_picker_sheet.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

void main() {
  setUpAll(() async {
    final FontLoader miSans = FontLoader('packages/novel_reader_ui/MiSans')
      ..addFont(
        rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'),
      );
    final FontLoader materialIcons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait(<Future<void>>[miSans.load(), materialIcons.load()]);
  });

  testWidgets('matches the compact light source picker visual baseline', (
    tester,
  ) async {
    await _setViewport(tester, const Size(768, 1496));
    await tester.pumpWidget(const _SourcePickerGoldenHost());
    await tester.tap(find.byKey(const Key('discovery-source-selector')));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/source_picker_compact_light.png'),
    );
  });
}

class _SourcePickerGoldenHost extends StatelessWidget {
  const _SourcePickerGoldenHost();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      themeMode: ThemeMode.light,
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        return MediaQuery(
          data: mediaQuery.copyWith(
            padding: const EdgeInsets.only(top: 24),
            viewPadding: const EdgeInsets.only(top: 24),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: Builder(
        builder: (context) => DiscoveryPage(
          onDestinationRequested: (AppNavigationDestination _) {},
          onToggleTheme: () {},
          onSourcePressed: () => showDiscoverySourcePicker(
            context,
            sources: _sources,
            selectedSourceId: _sources.first.id,
          ),
        ),
      ),
    );
  }
}

final List<PluginSourceDescriptor> _sources = <PluginSourceDescriptor>[
  for (final (String id, String name, PluginContentKind kind)
      in <(String, String, PluginContentKind)>[
        ('org.mgread.qidian', '起点中文网', PluginContentKind.novel),
        ('org.mgread.fanqie', '番茄小说', PluginContentKind.novel),
        ('org.mgread.qimao', '七猫中文网', PluginContentKind.novel),
        ('org.mgread.zongheng', '纵横中文网', PluginContentKind.novel),
        ('org.mgread.jinjiang', '晋江文学城', PluginContentKind.novel),
        ('org.mgread.17k', '17K 小说网', PluginContentKind.novel),
        ('org.mgread.xiaoxiang', '潇湘书院', PluginContentKind.novel),
        ('org.mgread.feilu', '飞卢小说网', PluginContentKind.novel),
        ('org.mgread.douban', '豆瓣阅读', PluginContentKind.novel),
        ('org.mgread.shuqi', '书旗小说', PluginContentKind.novel),
        ('org.mgread.ciweimao', '刺猬猫阅读', PluginContentKind.novel),
        ('org.mgread.zhangyue', '掌阅精选', PluginContentKind.novel),
        ('org.mgread.comic', '示例漫画源', PluginContentKind.manga),
      ])
    PluginSourceDescriptor(
      id: id,
      displayName: name,
      contentKinds: <PluginContentKind>[kind],
    ),
];

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 2;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump();
}
