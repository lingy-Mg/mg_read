import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/local_import/application/local_import_controller.dart';
import 'package:mg_read/features/local_import/data/local_import_ingress.dart';
import 'package:mg_read/features/local_import/presentation/local_import_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows file names delivered by a fake desktop open-with ingress', (tester) async {
    // Queue before the app controller subscribes to exercise launch-time
    // buffering; no file is read until the user starts the import.
    LocalImportIngress.instance.queuePaths(<String>[r'C:\fixtures\real-sample.txt']);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(localImportControllerProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LocalImportPage()),
      ),
    );
    await tester.pump();

    expect(controller.selected, hasLength(1));
    expect(find.text('real-sample.txt'), findsOneWidget);
    expect(find.text('选择文件'), findsOneWidget);
    expect(find.text('导入所选（1）'), findsOneWidget);
  });
}
