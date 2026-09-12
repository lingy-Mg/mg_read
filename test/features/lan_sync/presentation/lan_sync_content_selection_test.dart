import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/presentation/lan_sync_page.dart';

void main() {
  testWidgets('总选择和分组选择在全选时可以全不选', (tester) async {
    bool? selectAll;
    bool? selectShelf;
    bool? selectPlugins;

    await tester.pumpWidget(
      _SelectionTestApp(
        preview: _preview(selected: true),
        onSelectAll: (value) => selectAll = value,
        onSelectShelf: (value) => selectShelf = value,
        onSelectPlugins: (value) => selectPlugins = value,
      ),
    );

    await tester.tap(find.byKey(const Key('lan-sync-select-all')));
    await tester.tap(find.byKey(const Key('lan-sync-select-all-shelf')));
    await tester.tap(find.byKey(const Key('lan-sync-select-all-plugins')));

    expect(selectAll, isFalse);
    expect(selectShelf, isFalse);
    expect(selectPlugins, isFalse);
  });

  testWidgets('总选择和分组选择在未全选时可以全选', (tester) async {
    bool? selectAll;
    bool? selectShelf;
    bool? selectPlugins;

    await tester.pumpWidget(
      _SelectionTestApp(
        preview: _preview(selected: false),
        onSelectAll: (value) => selectAll = value,
        onSelectShelf: (value) => selectShelf = value,
        onSelectPlugins: (value) => selectPlugins = value,
      ),
    );

    await tester.tap(find.byKey(const Key('lan-sync-select-all')));
    await tester.tap(find.byKey(const Key('lan-sync-select-all-shelf')));
    await tester.tap(find.byKey(const Key('lan-sync-select-all-plugins')));

    expect(selectAll, isTrue);
    expect(selectShelf, isTrue);
    expect(selectPlugins, isTrue);
  });
}

final class _SelectionTestApp extends StatelessWidget {
  const _SelectionTestApp({required this.preview, required this.onSelectAll, required this.onSelectShelf, required this.onSelectPlugins});

  final LanSyncImportPreview preview;
  final ValueChanged<bool> onSelectAll;
  final ValueChanged<bool> onSelectShelf;
  final ValueChanged<bool> onSelectPlugins;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body: SingleChildScrollView(
        child: LanSyncContentSelection(
          manifest: _manifest,
          preview: preview,
          onSelectAll: onSelectAll,
          onSelectAllShelfItems: onSelectShelf,
          onSelectAllPlugins: onSelectPlugins,
          onPluginChanged: (_, _) {},
          onShelfItemChanged: (_, _) {},
        ),
      ),
    ),
  );
}

LanSyncImportPreview _preview({required bool selected}) => LanSyncImportPreview(
  newItemCount: 1,
  conflicts: const <LanSyncBookConflict>[],
  blockedItemCount: 0,
  pluginPlans: const <String, LanSyncPluginPlanState>{'source.example': LanSyncPluginPlanState.missing},
  selectedPluginIds: selected ? const <String>{'source.example'} : const <String>{},
  selectedShelfItemIds: selected ? <String>{_shelfItem.identity} : const <String>{},
);

const _plugin = LanSyncPluginDescriptor(
  id: 'source.example',
  version: '1.0.0',
  bytes: 3,
  artifactFormat: LanSyncPluginArtifactFormat.archive,
  checksum: '55bc801d',
  transferable: true,
  displayName: '示例数据源',
);

const _shelfItem = LanSyncShelfItem(
  pluginId: 'source.example',
  pluginVersion: '1.0.0',
  remoteContentId: 'book-1',
  contentKind: 'novel',
  title: '示例书籍',
);

const _manifest = LanSyncManifest(
  plugins: <LanSyncPluginDescriptor>[_plugin],
  shelfItems: <LanSyncShelfItem>[_shelfItem],
  skippedShelfItems: 0,
);
