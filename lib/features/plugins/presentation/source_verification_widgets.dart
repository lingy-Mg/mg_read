/// 检测页的状态摘要、实时阶段与可展开结果；只渲染会话快照，不持有 IO。
part of 'source_verification_page.dart';

class _VerificationOverview extends StatelessWidget {
  const _VerificationOverview({
    required this.running,
    required this.stopping,
    required this.progress,
    required this.report,
    required this.errorCode,
  });
  final bool running;
  final bool stopping;
  final SourceVerificationProgress? progress;
  final SourceVerificationReport? report;
  final String? errorCode;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final results = report?.sources ?? progress?.completedSources ?? const <SourceVerificationSourceResult>[];
    final total = report?.totalSources ?? progress?.totalSources ?? 0;
    final completed = results.where((source) => source.status != SourceVerificationResultStatus.cancelled).length;
    final passed = results.where((source) => source.status == SourceVerificationResultStatus.passed).length;
    final failed = results.where((source) => source.status == SourceVerificationResultStatus.failed).length;
    final interaction = results.where((source) => source.status == SourceVerificationResultStatus.interactionRequired).length;
    final title = stopping
        ? '正在中断检测'
        : running
        ? (total == 0 ? '正在准备检测' : '正在检测数据源')
        : report?.cancelled == true
        ? '检测已中断'
        : errorCode != null
        ? '检测未启动'
        : report?.isSuccessful == true
        ? '全部检测通过'
        : report != null
        ? '检测完成，存在待处理项'
        : '准备检测';
    final message = stopping
        ? '正在取消当前请求，后续检测不会继续。'
        : running
        ? (total == 0 ? '正在获取已启用的数据源…' : '已完成 $completed / $total 个数据源')
        : report?.cancelled == true
        ? '已完成 $completed${total > 0 ? ' / $total' : ''} 个数据源，保留本次已完成的结果。'
        : report != null
        ? '共检测 $total 个数据源 · 用时 ${_durationLabel(report!.duration)}'
        : '请检查数据源状态或网络设置后重试。';
    return Container(
      key: const Key('source-verification-overview'),
      padding: const EdgeInsets.all(AppSpacing.comfortable),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                running
                    ? Icons.radar
                    : report?.cancelled == true
                    ? Icons.stop_circle_outlined
                    : report?.isSuccessful == true
                    ? Icons.verified_outlined
                    : Icons.fact_check_outlined,
                color: tokens.dataSourceAccent,
              ),
              const SizedBox(width: AppSpacing.regular),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: AppSpacing.unit),
                    Text(message, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText)),
                  ],
                ),
              ),
            ],
          ),
          if (running) ...[
            const SizedBox(height: AppSpacing.comfortable),
            LinearProgressIndicator(value: total == 0 || stopping ? null : completed / total),
          ],
          if (results.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.comfortable),
            Wrap(
              spacing: AppSpacing.comfortable,
              runSpacing: AppSpacing.regular,
              children: [
                Text('通过 $passed', style: TextStyle(color: tokens.dataSourceAccent)),
                Text('失败 $failed', style: TextStyle(color: failed > 0 ? tokens.notification : tokens.mutedText)),
                Text('待处理 $interaction', style: TextStyle(color: tokens.mutedText)),
                if (results.any((source) => source.status == SourceVerificationResultStatus.cancelled))
                  Text(
                    '已中断 ${results.where((source) => source.status == SourceVerificationResultStatus.cancelled).length}',
                    style: TextStyle(color: tokens.mutedText),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SourceResultCard extends StatelessWidget {
  const _SourceResultCard({required this.source, this.activeStage});
  final SourceVerificationSourceResult source;
  final String? activeStage;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final active = activeStage != null;
    final failed = source.status == SourceVerificationResultStatus.failed;
    final color = active || source.status == SourceVerificationResultStatus.passed
        ? tokens.dataSourceAccent
        : failed
        ? tokens.notification
        : tokens.mutedText;
    final icon = active
        ? Icons.radar
        : switch (source.status) {
            SourceVerificationResultStatus.passed => Icons.check_circle_outline,
            SourceVerificationResultStatus.failed => Icons.error_outline,
            SourceVerificationResultStatus.interactionRequired => Icons.touch_app_outlined,
            SourceVerificationResultStatus.cancelled => Icons.stop_circle_outlined,
          };
    return Container(
      key: ValueKey<String>('source-verification-result-${source.pluginId}'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.divider),
      ),
      child: Material(
        color: Colors.transparent,
        child: ExpansionTile(
          key: ValueKey('${source.pluginId}-$active'),
          shape: const Border(),
          collapsedShape: const Border(),
          initiallyExpanded: active || source.status != SourceVerificationResultStatus.passed,
          tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.regular),
          childrenPadding: const EdgeInsets.fromLTRB(AppSpacing.regular, 0, AppSpacing.regular, AppSpacing.regular),
          leading: Icon(icon, color: color),
          title: Text(source.displayName),
          subtitle: Text(
            active
                ? '检测中 · ${activeStage == 'next' ? '准备下一阶段' : _stageLabel(activeStage!)}'
                : '${_sourceStatusLabel(source.status)} · ${_durationLabel(source.duration)}${source.version.isEmpty || source.version == 'unknown' ? '' : ' · v${source.version}'}',
            style: TextStyle(color: color),
          ),
          children: [
            for (final stage in source.stages)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.unit),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(_stageIcon(stage.status), size: 18, color: _stageColor(tokens, stage.status)),
                    const SizedBox(width: AppSpacing.regular),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_stageLabel(stage.stage)),
                          if (stage.code != null)
                            Text(
                              _stageCodeLabel(stage.code!),
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.unit),
                    Text(
                      '${_stageStatusLabel(stage.status)}\n${_durationLabel(stage.duration)}',
                      textAlign: TextAlign.right,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                    ),
                  ],
                ),
              ),
            if (activeStage != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.regular),
                child: Row(
                  children: [
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: AppSpacing.regular),
                    Expanded(child: Text(activeStage == 'next' ? '准备下一阶段…' : '${_stageLabel(activeStage!)}…')),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _durationLabel(Duration duration) => duration.inSeconds < 60
    ? '${(duration.inMilliseconds / 1000).toStringAsFixed(1)} 秒'
    : '${duration.inMinutes} 分 ${duration.inSeconds % 60} 秒';

String _stageCodeLabel(String code) => switch (code) {
  'internal' => '检测发生异常，请重试或查看应用诊断',
  'cancelled' => '已中断当前请求',
  'timeout' => '请求超时，请检查网络后重试',
  'resource_not_declared' => '数据源未提供封面资源',
  'resource_not_required' => '此内容无需资源检查',
  'video_playback_probe_unavailable' => '本次未验证实际视频播放',
  'resource_unreachable' => '资源无法访问',
  'chapters_truncated' => '返回的目录数量不足',
  'discovery_empty' => '发现页未返回可检测内容',
  'search_empty' => '搜索未返回内容',
  'content_interaction_required' || 'interaction_required' => '需要登录、验证或其他人工操作',
  _ => code,
};

class _VerificationMessage extends StatelessWidget {
  const _VerificationMessage({required this.icon, required this.title, required this.message, super.key});

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpacing.section),
    child: Column(
      children: <Widget>[
        Icon(icon, size: 40),
        const SizedBox(height: AppSpacing.regular),
        Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: AppSpacing.unit),
        Text(message, textAlign: TextAlign.center),
      ],
    ),
  );
}

String _stageLabel(String stage) {
  return switch (stage) {
    'runtime' => '引擎与数据源状态',
    'content.first' => '首章内容',
    'content.middle' => '中间章节内容',
    'content.last' => '末章内容',
    'playback.video' => '实际视频播放',
    'discover' => '发现',
    'search' => '搜索',
    'detail' => '详情',
    'chapters' => '完整目录',
    'content' => '首、中、末内容',
    'resource.cover' => '封面资源',
    'resource.content' => '正文或媒体资源',
    _ => '数据源检查',
  };
}

String _sourceStatusLabel(SourceVerificationResultStatus status) => switch (status) {
  SourceVerificationResultStatus.passed => '通过',
  SourceVerificationResultStatus.failed => '失败',
  SourceVerificationResultStatus.interactionRequired => '需要人工操作',
  SourceVerificationResultStatus.cancelled => '已中断',
};

String _stageStatusLabel(SourceVerificationStageStatus status) => switch (status) {
  SourceVerificationStageStatus.passed => '通过',
  SourceVerificationStageStatus.failed => '失败',
  SourceVerificationStageStatus.skipped => '跳过',
  SourceVerificationStageStatus.cancelled => '已中断',
};

IconData _stageIcon(SourceVerificationStageStatus status) => switch (status) {
  SourceVerificationStageStatus.passed => Icons.check_circle_outline,
  SourceVerificationStageStatus.failed => Icons.cancel_outlined,
  SourceVerificationStageStatus.skipped => Icons.remove_circle_outline,
  SourceVerificationStageStatus.cancelled => Icons.stop_circle_outlined,
};

Color _stageColor(AppThemeTokens tokens, SourceVerificationStageStatus status) => switch (status) {
  SourceVerificationStageStatus.passed => tokens.dataSourceAccent,
  SourceVerificationStageStatus.failed => tokens.notification,
  SourceVerificationStageStatus.skipped || SourceVerificationStageStatus.cancelled => tokens.mutedText,
};

String _runErrorMessage(String code) => switch (code) {
  'runtime_timeout' => 'Runtime 初始化超时，请检查 Node 状态后重试。',
  'source_list_empty' => '当前没有可检测的已启用数据源。',
  'source_not_found' => '该数据源未启用、未激活或已经移除。',
  _ => '自检引擎出现内部错误，请查看应用诊断后重试。',
};

void _ignore() {}
