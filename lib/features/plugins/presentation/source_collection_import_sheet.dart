/// Selection and result dialogs for importing a Node source collection.
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/source_collection_import.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

Future<SourceCollectionSelection?> showSourceCollectionImportSheet(
  BuildContext context,
  List<SourceCollectionCandidate> candidates, {
  bool onlineRepository = false,
}) => showModalBottomSheet<SourceCollectionSelection>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _SourceCollectionSelector(candidates: candidates, onlineRepository: onlineRepository),
);

Future<bool> showSourceUpdatesConfirmationDialog(BuildContext context, List<SourceCollectionCandidate> updates) async {
  if (updates.isEmpty) return false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('发现 ${updates.length} 个数据源更新'),
      content: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.55),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('确认后将覆盖已安装版本并更新数据源。'),
              const SizedBox(height: AppSpacing.compact),
              for (final update in updates)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.unit),
                  child: Text(
                    '${update.plugin.name}  v${_displayVersion(update.plan.receiverVersion ?? '--')} → v${_displayVersion(update.plugin.version)}',
                    style: Theme.of(dialogContext).textTheme.bodyMedium,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('暂不更新')),
        FilledButton(
          key: const Key('source-updates-confirm-overwrite'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('确认覆盖更新'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

Future<void> showSourceCollectionImportResults(
  BuildContext context,
  List<PluginTransferImportResult> results,
  List<SourceCollectionCandidate> candidates, {
  bool onlineRepository = false,
  bool updating = false,
  Set<String> pendingPluginIds = const {},
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) {
    final failed = results.where((item) => item.status == PluginTransferImportStatus.failed).length;
    final names = <String, String>{for (final item in candidates) item.plugin.id: item.plugin.name};
    final title = switch ((onlineRepository, updating, failed == 0)) {
      (true, true, true) => '数据源更新完成',
      (true, true, false) => '数据源更新部分失败',
      (true, false, true) => '在线数据源安装完成',
      (true, false, false) => '在线数据源安装部分失败',
      (false, _, true) => '合集导入完成',
      (false, _, false) => '合集导入部分失败',
    };
    return AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('成功 ${results.length - failed} 项，失败 $failed 项。'),
              if (pendingPluginIds.isNotEmpty) const Text('部分数据源已保存更新，重启后生效。'),
              const SizedBox(height: AppSpacing.compact),
              for (final result in results)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.unit),
                  child: Text(
                    '${result.status == PluginTransferImportStatus.installed ? '✓' : '×'}  ${names[result.pluginId] ?? result.pluginId}  v${_displayVersion(result.version)}  ${result.status == PluginTransferImportStatus.installed ? (updating ? '已更新' : '已安装') : (updating ? '更新失败或已隔离' : '安装失败或已隔离')}',
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('知道了'))],
    );
  },
);

class _SourceCollectionSelector extends StatefulWidget {
  const _SourceCollectionSelector({required this.candidates, required this.onlineRepository});

  final List<SourceCollectionCandidate> candidates;
  final bool onlineRepository;

  @override
  State<_SourceCollectionSelector> createState() => _SourceCollectionSelectorState();
}

class _SourceCollectionSelectorState extends State<_SourceCollectionSelector> {
  late final Set<String> _selectedIds = <String>{
    for (final candidate in widget.candidates)
      if (candidate.canImport && !candidate.requiresOverwriteChoice) candidate.plugin.id,
  };

  Set<String> get _importableIds => <String>{
    for (final item in widget.candidates)
      if (item.canImport) item.plugin.id,
  };

  @override
  Widget build(BuildContext context) {
    final selectedInstalled = widget.candidates
        .where((item) => item.requiresOverwriteChoice && _selectedIds.contains(item.plugin.id))
        .length;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.comfortable,
          0,
          AppSpacing.comfortable,
          AppSpacing.comfortable + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.84),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(widget.onlineRepository ? '在线插件仓库' : '导入数据源合集', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: AppSpacing.unit),
              Text('${widget.candidates.length} 个数据源 · 选择要安装或更新的项目', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: AppSpacing.compact),
              Wrap(
                spacing: AppSpacing.compact,
                children: <Widget>[
                  TextButton(
                    onPressed: _importableIds.isEmpty ? null : () => setState(() => _selectedIds.addAll(_importableIds)),
                    child: const Text('全选可导入'),
                  ),
                  TextButton(onPressed: _selectedIds.isEmpty ? null : () => setState(_selectedIds.clear), child: const Text('全不选')),
                ],
              ),
              if (selectedInstalled > 0)
                Container(
                  margin: const EdgeInsets.only(bottom: AppSpacing.compact),
                  padding: const EdgeInsets.all(AppSpacing.compact),
                  decoration: BoxDecoration(color: AppThemeTokens.of(context).mutedSurface, borderRadius: AppRadii.detailControl),
                  child: Text('将覆盖 $selectedInstalled 个已安装来源。相同版本也会重新安装；低于当前版本的降级不可选择。'),
                ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.candidates.length,
                  itemBuilder: (context, index) {
                    final candidate = widget.candidates[index];
                    final plugin = candidate.plugin;
                    final checked = _selectedIds.contains(plugin.id);
                    final enabled = candidate.canImport;
                    final action = candidate.plan.action;
                    final statusColor = _statusColor(action, Theme.of(context).colorScheme);
                    final guidance = switch (action) {
                      PluginTransferPlanAction.upgrade =>
                        '本地 v${_displayVersion(candidate.plan.receiverVersion ?? '--')} → 最新 v${_displayVersion(plugin.version)}',
                      PluginTransferPlanAction.same =>
                        '本地 v${_displayVersion(candidate.plan.receiverVersion ?? '--')} · 已是最新版本\n勾选后重新安装此版本',
                      PluginTransferPlanAction.receiverNewer =>
                        '本地 v${_displayVersion(candidate.plan.receiverVersion ?? '--')} → 仓库 v${_displayVersion(plugin.version)}\n合集版本可能造成降级',
                      PluginTransferPlanAction.missing => '仓库版本 v${_displayVersion(plugin.version)}',
                      PluginTransferPlanAction.developmentConflict => '由开发目录管理，需先处理来源冲突',
                      PluginTransferPlanAction.unavailable => _blockedReason(action),
                    };
                    return Container(
                      key: Key('source-collection-card-${plugin.id}'),
                      margin: const EdgeInsets.only(bottom: AppSpacing.compact),
                      child: Material(
                        color: checked
                            ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.28)
                            : AppThemeTokens.of(context).mutedSurface.withValues(alpha: 0.55),
                        shape: RoundedRectangleBorder(
                          borderRadius: AppRadii.detailCard,
                          side: BorderSide(
                            color: checked
                                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.38)
                                : Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.45),
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: CheckboxListTile(
                          key: Key('source-collection-${plugin.id}'),
                          value: checked,
                          onChanged: enabled
                              ? (value) => setState(() => value == true ? _selectedIds.add(plugin.id) : _selectedIds.remove(plugin.id))
                              : null,
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.compact, vertical: AppSpacing.unit),
                          visualDensity: VisualDensity.compact,
                          title: Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  plugin.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              const SizedBox(width: AppSpacing.compact),
                              _SourceStatusBadge(label: _statusLabel(action), color: statusColor),
                            ],
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: AppSpacing.unit),
                            child: Text(guidance, style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.35)),
                          ),
                          isThreeLine: action == PluginTransferPlanAction.same || action == PluginTransferPlanAction.receiverNewer,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: AppSpacing.compact),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
                  ),
                  const SizedBox(width: AppSpacing.compact),
                  Expanded(
                    child: FilledButton(
                      key: const Key('source-collection-import-selected'),
                      onPressed: _selectedIds.isEmpty
                          ? null
                          : () {
                              try {
                                Navigator.of(context).pop(sourceCollectionSelection(widget.candidates, _selectedIds));
                              } on SourceCollectionImportException catch (error) {
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
                              }
                            },
                      child: Text('导入 ${_selectedIds.length} 项'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceStatusBadge extends StatelessWidget {
  const _SourceStatusBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.compact, vertical: AppSpacing.unit),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w700),
      ),
    ),
  );
}

String _statusLabel(PluginTransferPlanAction action) => switch (action) {
  PluginTransferPlanAction.missing => '未安装',
  PluginTransferPlanAction.upgrade => '有更新',
  PluginTransferPlanAction.same => '已安装',
  PluginTransferPlanAction.receiverNewer => '不可降级',
  PluginTransferPlanAction.developmentConflict => '开发冲突',
  PluginTransferPlanAction.unavailable => '不可用',
};

Color _statusColor(PluginTransferPlanAction action, ColorScheme colorScheme) => switch (action) {
  PluginTransferPlanAction.missing => colorScheme.tertiary,
  PluginTransferPlanAction.upgrade => colorScheme.primary,
  PluginTransferPlanAction.same => colorScheme.secondary,
  PluginTransferPlanAction.receiverNewer ||
  PluginTransferPlanAction.developmentConflict ||
  PluginTransferPlanAction.unavailable => colorScheme.error,
};

String _displayVersion(String version) {
  final buildMarker = version.indexOf('-devsync.');
  return buildMarker > 0 ? version.substring(0, buildMarker) : version;
}

String _blockedReason(PluginTransferPlanAction action) => switch (action) {
  PluginTransferPlanAction.receiverNewer => '当前已安装版本更新，合集版本可能造成降级。',
  PluginTransferPlanAction.developmentConflict => '当前来源由开发目录管理，需先处理开发来源冲突。',
  PluginTransferPlanAction.unavailable => 'Runtime 当前无法安装此来源。',
  _ => '当前不可导入。',
};
