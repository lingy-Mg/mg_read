/// TV 安装工作区：左侧批量选择、右侧数据源清单、底部固定确认。
/// 只展示共享选择状态；不可导入项可阅读原因，不能进入安装集合。
part of 'source_collection_import_sheet.dart';

class _TvSourceCollectionSelector extends StatelessWidget {
  const _TvSourceCollectionSelector({
    required this.candidates,
    required this.online,
    required this.selected,
    required this.onToggle,
    required this.onSelectAll,
    required this.onClear,
    required this.onSubmit,
  });
  final List<SourceCollectionCandidate> candidates;
  final bool online;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final VoidCallback? onSelectAll;
  final VoidCallback? onClear;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    final overwrite = candidates.where((item) => selected.contains(item.plugin.id) && item.requiresOverwriteChoice).length;
    return Column(
      key: const Key('tv-source-collection-selector'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(online ? '在线插件仓库' : '导入数据源合集', style: Theme.of(context).textTheme.headlineSmall),
        Expanded(
          child: TvSourceWorkspace(
            sidebar: ListView(
              padding: const EdgeInsets.all(4),
              children: [
                Text('已选 ${selected.length} / ${candidates.length}', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                TvFocusable(key: const Key('source-collection-select-all'), onPressed: onSelectAll, child: const Text('全选可导入')),
                const SizedBox(height: 12),
                TvFocusable(key: const Key('source-collection-clear'), onPressed: onClear, child: const Text('全不选')),
                const SizedBox(height: 20),
                Text(overwrite == 0 ? '选择数据源后，按确认勾选。' : '$overwrite 项将覆盖本地版本', style: Theme.of(context).textTheme.bodyLarge),
              ],
            ),
            child: candidates.isEmpty
                ? const Center(child: Text('仓库中暂无可用数据源'))
                : ListView(
                    key: const Key('tv-source-collection-list'),
                    padding: const EdgeInsets.all(4),
                    children: [
                      for (final candidate in candidates)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: TvFocusable(
                            key: Key('source-collection-${candidate.plugin.id}'),
                            autofocus: identical(candidate, candidates.first),
                            selected: selected.contains(candidate.plugin.id),
                            onPressed: () {
                              if (candidate.canImport) onToggle(candidate.plugin.id);
                            },
                            child: Row(
                              children: [
                                Icon(
                                  !candidate.canImport
                                      ? Icons.block_rounded
                                      : selected.contains(candidate.plugin.id)
                                      ? Icons.check_circle_rounded
                                      : Icons.circle_outlined,
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(candidate.plugin.name, style: Theme.of(context).textTheme.titleLarge),
                                      const SizedBox(height: 6),
                                      Text('${_statusLabel(candidate.plan.action)} · v${_displayVersion(candidate.plugin.version)}'),
                                      if (candidate.plan.receiverVersion != null)
                                        Text('本地 v${_displayVersion(candidate.plan.receiverVersion!)}'),
                                      if (!candidate.canImport) Text(_blockedReason(candidate.plan.action)),
                                      if (candidate.requiresOverwriteChoice && candidate.canImport) const Text('勾选后覆盖安装'),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        Row(
          children: [
            TvFocusable(key: const Key('source-collection-cancel'), onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
            const Spacer(),
            TvFocusable(key: const Key('source-collection-import-selected'), onPressed: onSubmit, child: Text('导入 ${selected.length} 项')),
          ],
        ),
      ],
    );
  }
}
