/// 管理写操作互斥回归：跨页面调用也不能绕过安装锁；重复卸载不能清掉真实进度。
/// 使用应用窄端口替身，不启动 Runtime 或文件选择器。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import '../../../core/diagnostics/diagnostics_testkit.dart';
import '../presentation/plugin_runtime_status_page_fixture.dart';

void main() {
  late ProviderContainer container;
  late _Gateway gateway;
  late DiagnosticsTestkit diagnostics;
  setUp(() {
    gateway = _Gateway();
    diagnostics = DiagnosticsTestkit();
    container = ProviderContainer(
      overrides: [
        diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
        pluginRuntimeGatewayProvider.overrideWithValue(gateway),
        pluginRuntimeConnectionProvider.overrideWith((ref) async => dataSourceManagementFixture),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await diagnostics.dispose();
  });

  test('active installation rejects toggles and uninstall without resetting its lock', () async {
    final completion = Completer<List<PluginTransferImportResult>?>();
    final importing = container.read(pluginRuntimeSourceImportProvider.notifier).importSourceCollection(() => completion.future);
    expect(container.read(pluginRuntimeSourceManagementBusyProvider), isTrue);
    final actions = container.read(pluginRuntimeSourceActionProvider.notifier);
    final conflict = throwsA(isA<AppError>().having((error) => error.code, 'code', AppErrorCode.conflict));
    await expectLater(actions.setEnabled(pluginId: 'a', enabled: false), conflict);
    await expectLater(actions.uninstall(pluginId: 'a'), conflict);
    await expectLater(actions.uninstallAll(), conflict);
    expect(container.read(pluginRuntimeSourceImportProvider).isImporting, isTrue);
    expect(gateway.writes, 0);
    completion.complete(null);
    await importing;
    expect(container.read(pluginRuntimeSourceManagementBusyProvider), isFalse);
  });

  test('pending source mutation rejects local and collection imports before IO', () async {
    final toggling = container.read(pluginRuntimeSourceActionProvider.notifier).setEnabled(pluginId: 'a', enabled: false);
    final importer = container.read(pluginRuntimeSourceImportProvider.notifier);
    expect(await importer.importLocalPlugin(), isFalse);
    expect(await importer.importSourceCollection(() async => fail('must not start planning')), isNull);
    expect(gateway.imports, 0);
    expect(container.read(pluginRuntimeSourceManagementBusyProvider), isTrue);
    gateway.completion.complete();
    await toggling;
    expect(container.read(pluginRuntimeSourceManagementBusyProvider), isFalse);
  });

  test('a second bulk removal cannot reset the first operation progress', () async {
    final actions = container.read(pluginRuntimeSourceActionProvider.notifier);
    final removing = actions.uninstallAll(totalItems: 6);
    await expectLater(actions.uninstallAll(totalItems: 99), throwsA(isA<AppError>()));
    expect(container.read(pluginRuntimeSourceRemovalProgressProvider).isRemoving, isTrue);
    expect(container.read(pluginRuntimeSourceRemovalProgressProvider).totalItems, 6);
    gateway.completion.complete();
    await removing;
    expect(container.read(pluginRuntimeSourceRemovalProgressProvider).isRemoving, isFalse);
    expect(gateway.writes, 1);
  });
}

class _Gateway implements PluginRuntimeGateway {
  final completion = Completer<void>();
  int writes = 0;
  int imports = 0;
  @override
  Stream<RuntimeInitializationProgress> get initialization => const Stream.empty();
  @override
  Future<void> setEnabled({required String pluginId, required bool enabled}) {
    writes++;
    return completion.future;
  }

  @override
  Future<void> uninstallAll() {
    writes++;
    return completion.future;
  }

  @override
  Future<bool> importLocalPlugin() async {
    imports++;
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
