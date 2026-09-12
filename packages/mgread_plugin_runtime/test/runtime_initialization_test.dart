import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  test('decodes structured installed catalog startup diagnostics', () {
    final progress = RuntimeInitializationProgress.fromPlatform(
      catalogState: 'hit',
      completedBytes: 66,
      detail: '稳定数据源快照完成，共 66 项，目录索引=hit',
      durationMicros: 12345,
      itemCount: 66,
      stage: 'installed_plugins_snapshotted',
      totalBytes: 66,
    );

    expect(progress, isNotNull);
    expect(
      progress!.stage,
      RuntimeInitializationStage.installedPluginsSnapshotted,
    );
    expect(progress.catalogState, 'hit');
    expect(progress.durationMicros, 12345);
    expect(progress.itemCount, 66);
  });

  test('rejects invalid catalog startup diagnostic metadata', () {
    expect(
      RuntimeInitializationProgress.fromPlatform(
        catalogState: 'unknown',
        completedBytes: 1,
        durationMicros: -1,
        itemCount: -1,
        stage: 'installed_plugins_snapshotted',
        totalBytes: 1,
      ),
      isNull,
    );
  });
}
