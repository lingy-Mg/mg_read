/// 同步实际处理阶段的临时亮屏需求；每个异步操作独立持有，finally 成对释放。
/// 不保存偏好、不改变沉浸模式，与阅读器共用聚合协调器。平台失败不覆盖同步结果，
/// 慢平台调用不阻塞同步或取消；过期调用的最终状态由协调器修正。
library;

import 'package:novel_reader_ui/novel_reader_ui.dart';

final class LanSyncScreenAwake {
  LanSyncScreenAwake() {
    ScreenAwakeCoordinator.instance.acquire(this).ignore();
  }

  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    ScreenAwakeCoordinator.instance.release(this).ignore();
  }

  static Future<T> run<T>(Future<T> Function() action) async {
    final awake = LanSyncScreenAwake();
    try {
      return await action();
    } finally {
      await awake.close();
    }
  }
}
