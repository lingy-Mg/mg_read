/// Discovery failure presentation keeps a human-readable cause, next step and diagnostic context.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/discovery_page_controller.dart';
import 'package:mg_read/features/discovery/application/discovery_page_state.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/discovery_destination_page.dart';

void main() {
  testWidgets('explains a cancelled discovery request and gives a safe next step', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [discoveryPageControllerProvider.overrideWith(_CancelledDiscoveryPageController.new)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: DiscoveryDestinationPage(onDestinationRequested: (_) {}),
        ),
      ),
    );

    expect(find.text('已取消本次发现加载'), findsOneWidget);
    expect(find.textContaining('调用阶段：发现内容加载（source.discover.v1）'), findsOneWidget);
    expect(find.textContaining('请求在获得内容前被新的页面操作中止。'), findsOneWidget);
    expect(find.textContaining('停留在当前页后点“刷新”。'), findsOneWidget);
    expect(
      find.textContaining('诊断位置：pluginId=org.mgread.jinpai-video / capability=source.discover.v1 / runtime.invocation'),
      findsOneWidget,
    );
    expect(find.text('稳定错误码：cancelled'), findsOneWidget);
  });
}

final class _CancelledDiscoveryPageController extends DiscoveryPageController {
  @override
  DiscoveryPageState build() => DiscoveryPageState.failure(
    sources: <PluginSourceDescriptor>[
      PluginSourceDescriptor(
        id: 'org.mgread.jinpai-video',
        displayName: '金牌影院',
        contentKinds: const <PluginContentKind>[PluginContentKind.video],
      ),
    ],
    selectedSourceId: 'org.mgread.jinpai-video',
    error: AppError.fromCode(
      AppErrorCode.cancelled,
      detail: 'The plugin request was cancelled.',
      location: 'pluginId=org.mgread.jinpai-video / capability=source.discover.v1 / runtime.invocation',
    ),
    canNavigateBack: false,
    navigationDepth: 0,
    target: null,
    previousResult: null,
  );
}
