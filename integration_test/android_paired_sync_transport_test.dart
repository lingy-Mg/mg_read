/// Android 设备上的已配对 HTTP 同步传输回归入口。
///
/// 复用传输层完整测试套件，使 HMAC HTTP 会话、任务清单、独立插件制品和
/// 有界并发实际运行在 Android 的网络栈与临时文件系统中。
///
/// 本入口不替代 Windows/Android 双设备人工验收。
library;

import 'package:integration_test/integration_test.dart';

import '../test/features/lan_sync/data/paired_sync_transport_test.dart' as paired_sync_transport_test;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  paired_sync_transport_test.main();
}
