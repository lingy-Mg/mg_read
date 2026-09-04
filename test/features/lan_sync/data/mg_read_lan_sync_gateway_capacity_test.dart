/// LAN 网关书架容量错误传播测试。
///
/// 验证接收端批量写入超限时，Content Library 的业务错误会被翻译为稳定网关错误，
/// 且整个书架批次保持原子性。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/data/mg_read_lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

void main() {
  test('translates an over-capacity LAN batch without partial shelf writes', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-lan-capacity-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    for (var index = 0; index < bookshelfMaxItemCount - 1; index++) {
      await library.addLibraryItem(
        BookshelfAddRequest(
          title: '本地书籍 $index',
          author: null,
          kind: ContentKind.novel,
          pluginId: 'fixture',
          pluginVersion: '1.0.0',
          remoteContentId: 'local-$index',
        ),
      );
    }
    final gateway = MgReadLanSyncGateway(library, PluginRuntime());
    final manifest = LanSyncManifest(
      plugins: const <LanSyncPluginDescriptor>[],
      shelfItems: <LanSyncShelfItem>[_shelfItem('incoming-1'), _shelfItem('incoming-2')],
      skippedShelfItems: 0,
    );

    await expectLater(
      gateway.applyImport(
        manifest: manifest,
        conflictChoices: const <String, LanSyncConflictChoice>{},
        availablePluginIds: const <String>{'fixture'},
        pluginResult: const LanSyncPluginImportResult(availablePluginIds: <String>{'fixture'}, installed: 0, skipped: 0, failed: 0),
      ),
      throwsA(isA<LanSyncGatewayException>().having((error) => error.code, 'code', bookshelfCapacityExceededCode)),
    );
    expect((await library.listLibrary(const LibraryQuery(limit: bookshelfMaxItemCount))).items, hasLength(bookshelfMaxItemCount - 1));
  });
}

LanSyncShelfItem _shelfItem(String remoteContentId) => LanSyncShelfItem(
  pluginId: 'fixture',
  pluginVersion: '1.0.0',
  remoteContentId: remoteContentId,
  contentKind: 'novel',
  title: remoteContentId,
);
