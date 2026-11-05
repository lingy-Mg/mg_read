/// TV 检测工作区：运行控制和筛选独立于结果滚动，逐项阶段在阅读弹窗中展开。
/// 复用页面会话、取消令牌和报告；不启动第二次检测或改变检测结论。
part of 'source_verification_page.dart';

extension on _SourceVerificationPageState {
  Widget _buildTvResults(List<SourceVerificationSourceResult> visible, int completed, bool active) {
    final current = _progress;
    return TvSourceWorkspace(
      key: const Key('source-verification-content'),
      sidebar: ListView(
        padding: const EdgeInsets.all(4),
        children: [
          TvFocusable(
            key: Key(_running ? 'source-verification-cancel' : 'source-verification-restart'),
            onPressed: _running ? (_stopping ? null : _stop) : _start,
            child: Row(
              children: [
                Icon(_running ? Icons.stop_circle_outlined : Icons.refresh),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _stopping
                        ? '正在中断…'
                        : _running
                        ? '中断检测'
                        : '重新检测',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          for (final filter in _ResultFilter.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TvFocusable(
                key: Key('tv-verification-filter-${filter.name}'),
                selected: _filter == filter,
                onPressed: () => _selectFilter(filter),
                child: Text(switch (filter) {
                  _ResultFilter.all => '全部结果',
                  _ResultFilter.issues => '异常 / 待处理',
                  _ResultFilter.passed => '通过',
                }),
              ),
            ),
          SourceManagementInfo(
            child: _VerificationOverview(
              running: _running,
              stopping: _stopping,
              progress: current,
              report: _report,
              errorCode: _runErrorCode,
            ),
          ),
        ],
      ),
      child: ListView(
        key: ValueKey('tv-verification-results-${_filter.name}'),
        padding: const EdgeInsets.all(4),
        children: [
          Text('检测结果 · $completed', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          if (_runErrorCode != null)
            _VerificationMessage(
              key: const Key('source-verification-run-failure'),
              icon: Icons.error_outline,
              title: _runErrorCode == 'source_list_empty' ? '暂无可检测的数据源' : '无法开始检测',
              message: _runErrorMessage(_runErrorCode!),
            ),
          if (active && current != null)
            TvSourcePanel(
              title: current.displayName,
              icon: Icons.radar,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [Text('检测中 · ${_stageLabel(current.stage)}'), const SizedBox(height: 12), const LinearProgressIndicator()],
              ),
            ),
          if (completed > 0 && visible.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('暂无符合条件的结果')),
          for (final source in visible)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _TvVerificationResult(source: source),
            ),
          const SizedBox(height: 16),
          const SourceManagementInfo(child: Text('检测检查发现、搜索、详情、目录、内容和资源。跳过不代表通过；资源可访问不代表实际播放成功。检测不会写入书架。')),
        ],
      ),
    );
  }
}

class _TvVerificationResult extends StatelessWidget {
  const _TvVerificationResult({required this.source});
  final SourceVerificationSourceResult source;
  @override
  Widget build(BuildContext context) => TvFocusable(
    key: ValueKey('source-verification-result-${source.pluginId}'),
    onPressed: () => showSourceManagementDialog<void>(
      context: context,
      builder: (context) => SourceManagementDialog(
        title: Text('${source.displayName} · ${_sourceStatusLabel(source.status)}'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final stage in source.stages)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(_stageIcon(stage.status), color: _stageColor(AppThemeTokens.of(context), stage.status)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${_stageLabel(stage.stage)} · ${_stageStatusLabel(stage.status)}'),
                          if (stage.code != null) Text(_stageCodeLabel(stage.code!)),
                          Text(_durationLabel(stage.duration)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (source.stages.isEmpty) const Text('本轮没有完成的检测阶段'),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('返回'))],
      ),
    ),
    child: Row(
      children: [
        Icon(
          source.status == SourceVerificationResultStatus.passed ? Icons.check_circle_outline : Icons.info_outline,
          color: source.status == SourceVerificationResultStatus.passed
              ? AppThemeTokens.of(context).success
              : AppThemeTokens.of(context).warning,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(source.displayName, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text('${_sourceStatusLabel(source.status)} · ${_durationLabel(source.duration)}'),
            ],
          ),
        ),
        const Icon(Icons.chevron_right_rounded),
      ],
    ),
  );
}
