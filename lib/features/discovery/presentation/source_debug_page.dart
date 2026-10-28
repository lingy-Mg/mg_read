/// 自动巡检页面：展示真实发现/详情组件、检查进度和逐源报告。
///
/// 页面拥有巡检控制器及独立 Navigator，关闭即取消；自动预览不接受内容操作。
/// 详情复用本轮已检查的快照，不重复请求，也不修改主发现页选择或阅读记录。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/application/source_debug_controller.dart';
import 'runtime_discovery_page.dart';
import 'source_content_detail_sheet.dart';
import 'source_preview_page.dart';

Future<void> showSourceDebugPage(
  BuildContext context, {
  required SourceContentGateway gateway,
  required List<PluginSourceDescriptor> sources,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => SourceDebugPage(gateway: gateway, sources: sources),
  ),
);

class SourceDebugPage extends StatefulWidget {
  const SourceDebugPage({required this.gateway, required this.sources, super.key});
  final SourceContentGateway gateway;
  final List<PluginSourceDescriptor> sources;

  @override
  State<SourceDebugPage> createState() => _SourceDebugPageState();
}

class _SourceDebugPageState extends State<SourceDebugPage> {
  late final SourceDebugController _controller;

  @override
  void initState() {
    super.initState();
    _controller = SourceDebugController(gateway: widget.gateway, sources: widget.sources);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_controller.run());
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) {
      final source = _controller.currentSource;
      final results = _controller.results;
      final passed = results.where((value) => value.outcome == SourceDebugOutcome.passed).length;
      final failed = results.where((value) => value.outcome == SourceDebugOutcome.failed).length;
      return Scaffold(
        appBar: AppBar(
          title: const Text('数据源 Debug'),
          actions: [
            if (_controller.running) TextButton(key: const Key('source-debug-stop'), onPressed: _controller.stop, child: const Text('停止')),
            IconButton(
              tooltip: '复制检查报告',
              onPressed: results.isEmpty
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: _controller.report));
                      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('检查报告已复制')));
                    },
              icon: const Icon(Icons.copy_outlined),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _controller.running
                          ? '${_controller.index + 1}/${widget.sources.length} · ${source?.displayName ?? ''}'
                          : _controller.stage,
                      key: const Key('source-debug-progress'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _controller.running
                          ? _controller.stage
                          : '已检查 ${results.length}/${widget.sources.length} · 通过 $passed · 失败 $failed · 未验证 ${results.where((value) => value.outcome == SourceDebugOutcome.skipped).length}',
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: widget.sources.isEmpty ? 0 : results.length / widget.sources.length),
                    const SizedBox(height: 8),
                    Text('自动切换并打开首个资源，检查目录及首章解析。图片下载和音视频播放需另行确认。', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              if (_controller.running && source != null) ...[
                Expanded(
                  child: AbsorbPointer(
                    child: SourcePreviewScope(
                      child: _DebugSourcePreview(key: ValueKey(source.id), controller: _controller, source: source),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: results.isEmpty
                      ? null
                      : () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          useSafeArea: true,
                          builder: (_) => FractionallySizedBox(heightFactor: .7, child: _DebugResults(results: results)),
                        ),
                  child: Text('查看已完成结果（${results.length}）'),
                ),
              ] else
                Expanded(child: _DebugResults(results: results)),
            ],
          ),
        ),
      );
    },
  );
}

class _DebugResults extends StatelessWidget {
  const _DebugResults({required this.results});
  final List<SourceDebugResult> results;

  @override
  Widget build(BuildContext context) => results.isEmpty
      ? const Center(child: Text('暂无检查结果'))
      : ListView.separated(
          itemCount: results.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final result = results[index];
            return ListTile(
              key: ValueKey('source-debug-result-${result.source.id}'),
              leading: Icon(switch (result.outcome) {
                SourceDebugOutcome.passed => Icons.check_circle_outline,
                SourceDebugOutcome.failed => Icons.error_outline,
                SourceDebugOutcome.skipped => Icons.help_outline,
                SourceDebugOutcome.cancelled => Icons.stop_circle_outlined,
              }),
              title: Text('${result.source.displayName} · ${result.label}'),
              subtitle: SelectableText('${result.stage}${result.title == null ? '' : ' · ${result.title}'}\n${result.message}'),
              isThreeLine: true,
            );
          },
        );
}

class _DebugSourcePreview extends StatefulWidget {
  const _DebugSourcePreview({required this.controller, required this.source, super.key});
  final SourceDebugController controller;
  final PluginSourceDescriptor source;

  @override
  State<_DebugSourcePreview> createState() => _DebugSourcePreviewState();
}

class _DebugSourcePreviewState extends State<_DebugSourcePreview> {
  bool _openedDetail = false;

  @override
  Widget build(BuildContext context) => Navigator(
    onGenerateRoute: (_) => MaterialPageRoute<void>(
      builder: (innerContext) => AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final controller = widget.controller;
          final PluginContentDetail? detail = controller.detail;
          final catalog = controller.catalog;
          if (!_openedDetail && detail != null && catalog != null) {
            _openedDetail = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || !innerContext.mounted || controller.stopped || controller.currentSource?.id != widget.source.id) return;
              unawaited(
                showSourceContentDetailSheet(
                  innerContext,
                  gateway: controller.gateway,
                  pluginId: widget.source.id,
                  pluginVersion: widget.source.pluginVersion,
                  id: detail.summary.id,
                  initialContent: controller.content,
                  initialDetail: detail,
                  initialCatalog: catalog,
                  initialSourceName: widget.source.displayName,
                  refreshInitialContent: false,
                ),
              );
            });
          }
          return RuntimeDiscoveryPage(
            result: controller.discovery,
            sourceName: widget.source.displayName,
            isContentLoading: controller.discovery == null,
            onDestinationRequested: (_) {},
            onSourcePressed: () {},
            onTabSelected: (_) {},
            onCategorySelected: (_) {},
            onContentPressed: (_) {},
            onRefreshRequested: () {},
            onLoadMore: (_) {},
            canNavigateBack: false,
            onBackRequested: () {},
            loadingCollectionId: null,
          );
        },
      ),
    ),
  );
}
