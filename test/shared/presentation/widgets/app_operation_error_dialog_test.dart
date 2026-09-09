import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/shared/presentation/widgets/app_operation_error_dialog.dart';

void main() {
  testWidgets('copies stable context and the original app error reason', (WidgetTester tester) async {
    String? copiedPayload;
    final details = AppOperationErrorDetails.fromError(
      operation: '刷新书籍',
      error: AppError.fromCode(AppErrorCode.pluginExecutionFailed, detail: 'source returned an invalid catalog response'),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: AppOperationErrorDialog(details: details, onCopy: () async => copiedPayload = details.copyPayload),
        ),
      ),
    );

    expect(find.text('刷新书籍失败'), findsOneWidget);
    expect(find.text('source returned an invalid catalog response'), findsOneWidget);

    await tester.tap(find.byKey(const Key('app-operation-error-copy')));
    await tester.pump();

    expect(copiedPayload, '操作：刷新书籍\n错误码：plugin_execution_failed\n错误原因：source returned an invalid catalog response');
  });
}
