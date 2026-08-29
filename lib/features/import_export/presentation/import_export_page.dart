/// “我的”下的本地导入导出页面。
///
/// 职责：
/// - 展示导出与导入入口，并让用户逐项选择数据源、书架和阅读进度。
/// - 呈现稳定的进度、结果与可恢复错误，不显示本地路径或 artifact 内容。
/// - 导入成功后失效相关只读投影，使返回主页/数据源页时重新加载。
///
/// 注意：
/// - 页面不直接读写文件、数据库或 Runtime；所有操作经应用层协调器完成。
/// - 开发数据源提示必须明确“先打包、仅导出 artifact”。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/import_export/application/import_export_service.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/profile/application/profile_reading_stats_loader.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

class ImportExportPage extends ConsumerStatefulWidget {
  const ImportExportPage({required this.onBackRequested, this.coordinator, super.key});

  final VoidCallback onBackRequested;
  final ImportExportCoordinator? coordinator;

  @override
  ConsumerState<ImportExportPage> createState() => _ImportExportPageState();
}

class _ImportExportPageState extends ConsumerState<ImportExportPage> {
  ImportExportExportPlan? _exportPlan;
  ImportExportImportPlan? _importPlan;
  Set<String> _selectedPluginIds = <String>{};
  Set<String> _selectedShelfItemIds = <String>{};
  Map<String, LanSyncConflictChoice> _conflictChoices = <String, LanSyncConflictChoice>{};
  bool _busy = false;
  String? _feedback;
  bool _feedbackIsError = false;

  ImportExportCoordinator get _coordinator => widget.coordinator ?? ref.read(importExportCoordinatorProvider);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              AppSecondaryPageTopBar(title: '导入导出', onBack: widget.onBackRequested, backButtonKey: const Key('import-export-back')),
              Expanded(
                child: ListView(
                  key: const Key('import-export-content'),
                  padding: const EdgeInsets.fromLTRB(
                    AppDetailMetrics.horizontalPadding,
                    AppSpacing.regular,
                    AppDetailMetrics.horizontalPadding,
                    AppSpacing.section,
                  ),
                  children: <Widget>[
                    const _ScopeNotice(),
                    const SizedBox(height: AppSpacing.regular),
                    if (_feedback != null) ...<Widget>[
                      _FeedbackCard(message: _feedback!, isError: _feedbackIsError),
                      const SizedBox(height: AppSpacing.regular),
                    ],
                    if (_busy) ...<Widget>[
                      const LinearProgressIndicator(key: Key('import-export-progress')),
                      const SizedBox(height: AppSpacing.regular),
                    ],
                    if (_exportPlan == null && _importPlan == null) ...<Widget>[
                      _ActionCard(
                        key: const Key('prepare-export'),
                        icon: Icons.upload_file_rounded,
                        title: '导出到文件',
                        description: '预览本机项目，然后选择要写入备份的数据源、书架和阅读进度。',
                        onTap: _busy ? null : _prepareExport,
                      ),
                      const SizedBox(height: AppSpacing.regular),
                      _ActionCard(
                        key: const Key('pick-import'),
                        icon: Icons.download_rounded,
                        title: '从文件导入',
                        description: '先检查文件内容和本机版本，再选择实际导入的项目。',
                        onTap: _busy ? null : _pickImport,
                      ),
                    ],
                    if (_exportPlan case final plan?) _buildExportSelection(plan),
                    if (_importPlan case final plan?) _buildImportSelection(plan),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExportSelection(ImportExportExportPlan plan) {
    return _SelectionPanel(
      title: '选择导出项目',
      description: '未勾选的项目不会写入文件。不可打包的数据源不会导出。',
      pluginRows: <Widget>[
        for (final plugin in plan.manifest.plugins)
          CheckboxListTile(
            key: Key('export-plugin-${plugin.id}'),
            value: _selectedPluginIds.contains(plugin.id),
            onChanged: !plugin.transferable || _busy ? null : (value) => _togglePlugin(plugin.id, value),
            title: Text(plugin.displayName ?? plugin.id),
            subtitle: Text(
              plugin.transferable
                  ? '${plugin.version} · ${_artifactLabel(plugin.artifactFormat)} · ${_formatBytes(plugin.bytes)}'
                  : '当前数据源无法生成可导出的 artifact',
            ),
          ),
      ],
      shelfRows: <Widget>[
        for (final item in plan.manifest.shelfItems)
          CheckboxListTile(
            key: Key('export-shelf-${item.identity}'),
            value: _selectedShelfItemIds.contains(item.identity),
            onChanged: _busy ? null : (value) => _toggleShelf(item.identity, value),
            title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(item.progress == null ? '书架项目' : '书架项目 · 包含阅读进度'),
          ),
      ],
      selectedPlugins: _selectedPluginIds.length,
      selectedShelfItems: _selectedShelfItemIds.length,
      onSelectAllPlugins: _busy ? null : (selected) => _selectExportPlugins(plan, selected),
      onSelectAllShelfItems: _busy ? null : (selected) => _selectShelfItems(plan.manifest.shelfItems, selected),
      footer: _SelectionActions(
        primaryKey: const Key('export-selected'),
        primaryLabel: '导出所选项目',
        primaryIcon: Icons.save_alt_rounded,
        primaryEnabled: !_busy && (_selectedPluginIds.isNotEmpty || _selectedShelfItemIds.isNotEmpty),
        onPrimary: _exportSelected,
        onCancel: _reset,
      ),
    );
  }

  Widget _buildImportSelection(ImportExportImportPlan plan) {
    return _SelectionPanel(
      title: '选择导入项目',
      description: '相同或更高版本的数据源会保留本机版本；书架冲突默认智能合并。',
      pluginRows: <Widget>[
        for (final plugin in plan.manifest.plugins)
          CheckboxListTile(
            key: Key('import-plugin-${plugin.id}'),
            value: _selectedPluginIds.contains(plugin.id),
            onChanged: !_canImportPlugin(plan, plugin.id) || _busy ? null : (value) => _togglePlugin(plugin.id, value),
            title: Text(plugin.displayName ?? plugin.id),
            subtitle: Text('${plugin.version} · ${_pluginPlanLabel(plan.preview.pluginPlans[plugin.id])}'),
          ),
      ],
      shelfRows: <Widget>[
        for (final item in plan.manifest.shelfItems) ...<Widget>[
          CheckboxListTile(
            key: Key('import-shelf-${item.identity}'),
            value: _selectedShelfItemIds.contains(item.identity),
            onChanged: _busy ? null : (value) => _toggleShelf(item.identity, value),
            title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(item.progress == null ? '书架项目' : '书架项目 · 包含阅读进度'),
          ),
          if (_selectedShelfItemIds.contains(item.identity))
            if (_conflictFor(plan, item.identity) case final conflict?)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.section, 0, AppSpacing.section, AppSpacing.compact),
                child: DropdownButtonFormField<LanSyncConflictChoice>(
                  key: Key('import-conflict-${item.identity}'),
                  initialValue: _conflictChoices[item.identity] ?? LanSyncConflictChoice.smartMerge,
                  decoration: const InputDecoration(labelText: '书架冲突处理'),
                  items: const <DropdownMenuItem<LanSyncConflictChoice>>[
                    DropdownMenuItem(value: LanSyncConflictChoice.smartMerge, child: Text('智能合并')),
                    DropdownMenuItem(value: LanSyncConflictChoice.useSender, child: Text('采用备份')),
                    DropdownMenuItem(value: LanSyncConflictChoice.keepLocal, child: Text('保留本机')),
                  ],
                  onChanged: _busy ? null : (value) => _setConflictChoice(conflict.identity, value),
                ),
              ),
        ],
      ],
      selectedPlugins: _selectedPluginIds.length,
      selectedShelfItems: _selectedShelfItemIds.length,
      onSelectAllPlugins: _busy ? null : (selected) => _selectImportPlugins(plan, selected),
      onSelectAllShelfItems: _busy ? null : (selected) => _selectShelfItems(plan.manifest.shelfItems, selected),
      footer: _SelectionActions(
        primaryKey: const Key('import-selected'),
        primaryLabel: '导入所选项目',
        primaryIcon: Icons.download_done_rounded,
        primaryEnabled: !_busy && (_selectedPluginIds.isNotEmpty || _selectedShelfItemIds.isNotEmpty),
        onPrimary: _importSelected,
        onCancel: _reset,
      ),
    );
  }

  Future<void> _prepareExport() async {
    await _run(() async {
      final plan = await _coordinator.prepareExport();
      if (!mounted) return;
      setState(() {
        _exportPlan = plan;
        _selectedPluginIds = plan.defaultPluginIds;
        _selectedShelfItemIds = plan.defaultShelfItemIds;
        _feedback = null;
      });
    }, failureMessage: '无法读取可导出的项目，请确认数据源运行环境可用。');
  }

  Future<void> _pickImport() async {
    await _run(() async {
      final plan = await _coordinator.pickImport();
      if (!mounted || plan == null) return;
      setState(() {
        _importPlan = plan;
        _selectedPluginIds = Set<String>.from(plan.preview.recommendedPluginIds);
        _selectedShelfItemIds = Set<String>.from(plan.preview.selectedShelfItemIds);
        _conflictChoices = <String, LanSyncConflictChoice>{
          for (final conflict in plan.preview.conflicts) conflict.identity: conflict.choice,
        };
        _feedback = null;
      });
    }, failureMessage: '文件无效、已损坏或超过导入限制。');
  }

  Future<void> _exportSelected() async {
    final plan = _exportPlan;
    if (plan == null) return;
    await _run(() async {
      final saved = await _coordinator.exportSelection(plan, pluginIds: _selectedPluginIds, shelfItemIds: _selectedShelfItemIds);
      if (!mounted || !saved) return;
      setState(() {
        _exportPlan = null;
        _feedback = '导出完成。文件只包含所选项目和打包后的数据源 artifact。';
        _feedbackIsError = false;
      });
    }, failureMessage: '导出失败，原有目标文件不会被不完整内容替换。');
  }

  Future<void> _importSelected() async {
    final plan = _importPlan;
    if (plan == null) return;
    await _run(() async {
      final result = await _coordinator.importSelection(
        plan,
        pluginIds: _selectedPluginIds,
        shelfItemIds: _selectedShelfItemIds,
        conflictChoices: _conflictChoices,
      );
      if (!mounted) return;
      ref.invalidate(pluginRuntimeConnectionProvider);
      ref.invalidate(pluginRuntimeStatusProvider);
      ref.invalidate(libraryPageControllerProvider);
      ref.invalidate(profileReadingStatsProvider);
      setState(() {
        _importPlan = null;
        _feedback = '导入完成：数据源 ${result.pluginInstalled} 个，新增书架 ${result.added} 项，更新 ${result.updated} 项，阻止 ${result.blocked} 项。';
        _feedbackIsError = result.pluginFailed > 0 || result.blocked > 0;
      });
    }, failureMessage: '导入未完成；已安装版本和未选项目保持不变，可重新选择文件后重试。');
  }

  Future<void> _run(Future<void> Function() action, {required String failureMessage}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _feedback = importExportFailureMessage(error, fallback: failureMessage);
          _feedbackIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _togglePlugin(String id, bool? selected) => setState(() {
    selected == true ? _selectedPluginIds.add(id) : _selectedPluginIds.remove(id);
  });

  void _toggleShelf(String id, bool? selected) => setState(() {
    selected == true ? _selectedShelfItemIds.add(id) : _selectedShelfItemIds.remove(id);
  });

  void _selectExportPlugins(ImportExportExportPlan plan, bool selected) => setState(() {
    _selectedPluginIds = selected ? plan.defaultPluginIds : <String>{};
  });

  void _selectImportPlugins(ImportExportImportPlan plan, bool selected) => setState(() {
    _selectedPluginIds = selected ? Set<String>.from(plan.preview.recommendedPluginIds) : <String>{};
  });

  void _selectShelfItems(List<LanSyncShelfItem> items, bool selected) => setState(() {
    _selectedShelfItemIds = selected ? <String>{for (final item in items) item.identity} : <String>{};
  });

  void _setConflictChoice(String id, LanSyncConflictChoice? choice) {
    if (choice != null) setState(() => _conflictChoices[id] = choice);
  }

  void _reset() => setState(() {
    _exportPlan = null;
    _importPlan = null;
    _selectedPluginIds = <String>{};
    _selectedShelfItemIds = <String>{};
    _conflictChoices = <String, LanSyncConflictChoice>{};
    _feedback = null;
  });
}

/// Converts stable import boundary failures into user-facing copy.
String importExportFailureMessage(Object error, {required String fallback}) =>
    error is LanSyncGatewayException && error.code == bookshelfCapacityExceededCode ? '书架已满，请先清理书籍。' : fallback;

class _ScopeNotice extends StatelessWidget {
  const _ScopeNotice();

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.regular),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.inventory_2_outlined),
          const SizedBox(width: AppSpacing.compact),
          Expanded(
            child: Text(
              '可导入导出数据源、书架和阅读进度，不包含正文、缓存、Cookie、凭据或设置。Windows 实时开发数据源会先打包，只导出 artifact，不导出源码。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    ),
  );
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.icon, required this.title, required this.description, required this.onTap, super.key});
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      onTap: onTap,
      borderRadius: AppRadii.control,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.section),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 32),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.unit),
                  Text(description),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    ),
  );
}

class _SelectionPanel extends StatelessWidget {
  const _SelectionPanel({
    required this.title,
    required this.description,
    required this.pluginRows,
    required this.shelfRows,
    required this.selectedPlugins,
    required this.selectedShelfItems,
    required this.onSelectAllPlugins,
    required this.onSelectAllShelfItems,
    required this.footer,
  });
  final String title;
  final String description;
  final List<Widget> pluginRows;
  final List<Widget> shelfRows;
  final int selectedPlugins;
  final int selectedShelfItems;
  final ValueChanged<bool>? onSelectAllPlugins;
  final ValueChanged<bool>? onSelectAllShelfItems;
  final Widget footer;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(title, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: AppSpacing.unit),
      Text(description),
      const SizedBox(height: AppSpacing.regular),
      _GroupCard(title: '数据源插件', count: selectedPlugins, rows: pluginRows, emptyText: '没有可处理的数据源', onSelectAll: onSelectAllPlugins),
      const SizedBox(height: AppSpacing.regular),
      _GroupCard(
        title: '书架与阅读进度',
        count: selectedShelfItems,
        rows: shelfRows,
        emptyText: '书架中没有可处理的项目',
        onSelectAll: onSelectAllShelfItems,
      ),
      const SizedBox(height: AppSpacing.regular),
      footer,
    ],
  );
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.title, required this.count, required this.rows, required this.emptyText, required this.onSelectAll});
  final String title;
  final int count;
  final List<Widget> rows;
  final String emptyText;
  final ValueChanged<bool>? onSelectAll;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: <Widget>[
        ListTile(
          title: Text(title, style: Theme.of(context).textTheme.titleMedium),
          subtitle: Text('已选择 $count 项'),
          trailing: TextButton(
            onPressed: rows.isEmpty || onSelectAll == null ? null : () => onSelectAll!(count != rows.length),
            child: Text(count == rows.length && rows.isNotEmpty ? '取消全选' : '全选'),
          ),
        ),
        const Divider(height: 1),
        if (rows.isEmpty) Padding(padding: const EdgeInsets.all(AppSpacing.regular), child: Text(emptyText)) else ...rows,
      ],
    ),
  );
}

class _SelectionActions extends StatelessWidget {
  const _SelectionActions({
    required this.primaryKey,
    required this.primaryLabel,
    required this.primaryIcon,
    required this.primaryEnabled,
    required this.onPrimary,
    required this.onCancel,
  });
  final Key primaryKey;
  final String primaryLabel;
  final IconData primaryIcon;
  final bool primaryEnabled;
  final VoidCallback onPrimary;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Expanded(
        child: OutlinedButton(onPressed: onCancel, child: const Text('取消')),
      ),
      const SizedBox(width: AppSpacing.compact),
      Expanded(
        flex: 2,
        child: FilledButton.icon(
          key: primaryKey,
          onPressed: primaryEnabled ? onPrimary : null,
          icon: Icon(primaryIcon),
          label: Text(primaryLabel),
        ),
      ),
    ],
  );
}

class _FeedbackCard extends StatelessWidget {
  const _FeedbackCard({required this.message, required this.isError});
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Semantics(
      liveRegion: true,
      child: Card(
        color: isError ? tokens.warning.withValues(alpha: 0.12) : tokens.accentSoft,
        child: ListTile(leading: Icon(isError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded), title: Text(message)),
      ),
    );
  }
}

LanSyncBookConflict? _conflictFor(ImportExportImportPlan plan, String identity) {
  for (final conflict in plan.preview.conflicts) {
    if (conflict.identity == identity) return conflict;
  }
  return null;
}

bool _canImportPlugin(ImportExportImportPlan plan, String id) => plan.preview.recommendedPluginIds.contains(id);

String _pluginPlanLabel(LanSyncPluginPlanState? state) => switch (state) {
  LanSyncPluginPlanState.missing => '本机缺失，可导入',
  LanSyncPluginPlanState.upgrade => '可升级',
  LanSyncPluginPlanState.sameVersion => '版本相同，保留本机',
  LanSyncPluginPlanState.receiverNewer => '本机版本更高，保留本机',
  LanSyncPluginPlanState.unavailable || null => '不可导入',
};

String _artifactLabel(LanSyncPluginArtifactFormat format) => switch (format) {
  LanSyncPluginArtifactFormat.singleFile => '.mgplugin.js',
  LanSyncPluginArtifactFormat.archive => '.mgplugin',
};

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}
