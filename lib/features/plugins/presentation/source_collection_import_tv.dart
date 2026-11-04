/// Remote-only presentation for the shared collection selection state.
/// Blocked entries remain remote-readable but cannot enter the selection.
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
  Widget build(BuildContext context) => Column(
    key: const Key('tv-source-collection-selector'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(online ? '在线插件仓库' : '导入数据源合集', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 8),
      Expanded(
        child: ListView(
          key: const Key('tv-source-collection-list'),
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                TvFocusable(key: const Key('source-collection-select-all'), onPressed: onSelectAll, child: const Text('全选可导入')),
                TvFocusable(key: const Key('source-collection-clear'), onPressed: onClear, child: const Text('全不选')),
              ],
            ),
            const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('上下选择数据源，按确定勾选。勾选已安装来源将覆盖当前版本。')),
            for (final candidate in candidates)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TvFocusable(
                  key: Key('source-collection-${candidate.plugin.id}'),
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
                            ? Icons.check_box_rounded
                            : Icons.check_box_outline_blank_rounded,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(candidate.plugin.name, style: Theme.of(context).textTheme.titleLarge),
                            Text(
                              '${_statusLabel(candidate.plan.action)} · v${_displayVersion(candidate.plugin.version)}'
                              '${candidate.plan.receiverVersion == null ? '' : ' · 本地 v${_displayVersion(candidate.plan.receiverVersion!)}'}',
                            ),
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
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TvFocusable(
              key: const Key('source-collection-cancel'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: TvFocusable(
              key: const Key('source-collection-import-selected'),
              onPressed: onSubmit,
              child: Text('导入 ${selected.length} 项'),
            ),
          ),
        ],
      ),
    ],
  );
}
