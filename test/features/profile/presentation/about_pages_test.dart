/// “关于我们”页面族的独立组件测试。
///
/// 职责：
/// - 验证关于页排除更新入口并只显示四个可用条目。
/// - 验证协议、隐私、开源许可与联系页面具备真实内容和交互。
///
/// 注意：
/// - 测试不加载根路由，避免与其他并发功能的编译状态耦合。
///
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/about_document_page.dart';
import 'package:mg_read/features/profile/presentation/about_page.dart';
import 'package:mg_read/features/profile/presentation/contact_page.dart';
import 'package:mg_read/features/profile/presentation/open_source_licenses_page.dart';

void main() {
  testWidgets('about page shows four completed items without update', (WidgetTester tester) async {
    await _setViewport(tester);
    final requestedItems = <String>[];
    await tester.pumpWidget(
      _host(AboutPage(appVersion: '9.8.7', onBackRequested: () {}, onDestinationRequested: (_) {}, onItemRequested: requestedItems.add)),
    );
    await tester.pumpAndSettle();

    expect(find.text('检查更新'), findsNothing);
    expect(find.byKey(const Key('about-action-update')), findsNothing);
    expect(find.byKey(const Key('about-action-agreement')), findsOneWidget);
    expect(find.byKey(const Key('about-action-privacy')), findsOneWidget);
    expect(find.byKey(const Key('about-action-licenses')), findsOneWidget);
    expect(find.byKey(const Key('about-action-contact')), findsOneWidget);
    expect(find.text('版本 9.8.7'), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('about-settings-card'))).height, 256);

    await tester.tap(find.byKey(const Key('about-action-agreement')));
    expect(requestedItems, <String>['agreement']);
  });

  testWidgets('agreement and privacy pages expose complete local sections', (WidgetTester tester) async {
    await _setViewport(tester);
    await tester.pumpWidget(_host(const AboutDocumentPage(kind: AboutDocumentKind.agreement, onBackRequested: _noop)));
    await tester.pumpAndSettle();

    expect(find.text('用户协议'), findsOneWidget);
    expect(find.textContaining('服务内容'), findsOneWidget);
    expect(find.text('4. 第三方内容'), findsOneWidget);
    expect(find.text('功能建设中'), findsNothing);

    await tester.pumpWidget(_host(const AboutDocumentPage(kind: AboutDocumentKind.privacy, onBackRequested: _noop)));
    await tester.pumpAndSettle();
    expect(find.text('隐私政策'), findsOneWidget);
    expect(find.textContaining('设备内数据'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('6. 管理与删除'),
      260,
      scrollable: find.descendant(of: find.byKey(const ValueKey<String>('about-document-privacy')), matching: find.byType(Scrollable)),
    );
    expect(find.text('6. 管理与删除'), findsOneWidget);
  });

  testWidgets('contact page opens the in-app feedback channel', (WidgetTester tester) async {
    await _setViewport(tester);
    var feedbackRequested = false;
    await tester.pumpWidget(
      _host(ContactPage(appVersion: '9.8.7', onBackRequested: _noop, onFeedbackRequested: () => feedbackRequested = true)),
    );
    await tester.pumpAndSettle();

    expect(find.text('应用内意见反馈'), findsOneWidget);
    expect(find.text('前往意见反馈'), findsOneWidget);
    expect(find.text('统一阅读 · 版本 9.8.7'), findsOneWidget);
    await tester.tap(find.byKey(const Key('contact-open-feedback')));
    expect(feedbackRequested, isTrue);
  });

  testWidgets('license page reads actual LicenseRegistry entries', (WidgetTester tester) async {
    LicenseRegistry.addLicense(
      () => Stream<LicenseEntry>.value(const LicenseEntryWithLineBreaks(<String>['mg_read_test_component'], 'MG Read test license text.')),
    );
    await _setViewport(tester);
    await tester.pumpWidget(_host(const OpenSourceLicensesPage(onBackRequested: _noop)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open-source-license-list')), findsOneWidget);
    expect(find.text('mg_read_test_component'), findsOneWidget);
    expect(find.text('功能建设中'), findsNothing);
  });
}

void _noop() {}

Widget _host(Widget child) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    builder: (BuildContext context, Widget? routedChild) {
      final mediaQuery = MediaQuery.of(context);
      return MediaQuery(
        data: mediaQuery.copyWith(padding: const EdgeInsets.only(top: 24), viewPadding: const EdgeInsets.only(top: 24)),
        child: routedChild ?? const SizedBox.shrink(),
      );
    },
    home: child,
  );
}

Future<void> _setViewport(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump();
}
