/// Import confirmation and local-library management UI. It consumes only the
/// path-free ContentLibrary facade and an app-scoped queue controller.
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/shared/presentation/widgets/local_document_image.dart';
import '../application/local_import_controller.dart';
import '../data/local_import_ingress.dart';
import 'local_document_detail_page.dart';

class LocalImportPage extends ConsumerWidget {
  const LocalImportPage({this.onReaderRequested, super.key});
  final ValueChanged<String>? onReaderRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(localImportControllerProvider);
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('本地书籍')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: <Widget>[
              Text('导入 TXT 或 EPUB', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 6),
              Text('支持 UTF-8、GB18030 等常见文本编码；单文件最大 256 MiB，每批最多 100 个。', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: controller.loading ? null : controller.pickFiles,
                    icon: const Icon(Icons.add),
                    label: const Text('选择文件'),
                  ),
                  if (controller.selected.isNotEmpty)
                    FilledButton.tonalIcon(
                      onPressed: controller.batchTotal > 0 ? null : controller.importSelected,
                      icon: const Icon(Icons.file_download_outlined),
                      label: Text('导入所选（${controller.selected.length}）'),
                    ),
                  if (controller.readyCount > 0)
                    FilledButton.tonalIcon(
                      onPressed: controller.commitReadyJobs,
                      icon: const Icon(Icons.done_all),
                      label: Text('按预览资料批量导入（${controller.readyCount}）'),
                    ),
                  if (Platform.isWindows)
                    OutlinedButton.icon(
                      onPressed: () async {
                        try {
                          final added = await LocalImportIngress.instance.registerOpenWith();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(added ? 'MgRead 已添加到 TXT 和 EPUB 的“打开方式”。' : '无法更新当前 Windows 用户的“打开方式”。')),
                            );
                          }
                        } on Object catch (error) {
                          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('注册失败：$error')));
                        }
                      },
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('添加到“打开方式”'),
                    ),
                ],
              ),
              if (controller.batchTotal > 0) ...<Widget>[
                const SizedBox(height: 12),
                LinearProgressIndicator(value: controller.batchCurrent / controller.batchTotal),
                Text('正在处理 ${controller.batchCurrent}/${controller.batchTotal}'),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: controller.stopRemainingBatch,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('停止本批后续文件'),
                  ),
                ),
              ],
              for (final input in controller.selected)
                ListTile(
                  key: ValueKey<String>('selected-${input.fileName}-${identityHashCode(input)}'),
                  leading: const Icon(Icons.description_outlined),
                  title: Text(input.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(input.bytes == null ? '大小将在读取时确认' : _formatBytes(input.bytes!)),
                  trailing: IconButton(tooltip: '移除', onPressed: () => controller.removeSelected(input), icon: const Icon(Icons.close)),
                ),
              for (final error in controller.errors.entries)
                Card(
                  color: colors.errorContainer,
                  child: ListTile(
                    leading: Icon(Icons.error_outline, color: colors.onErrorContainer),
                    title: Text(error.value, style: TextStyle(color: colors.onErrorContainer)),
                    subtitle: Text(error.key, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
              const Divider(height: 36),
              Row(
                children: <Widget>[
                  Expanded(child: Text('导入任务', style: Theme.of(context).textTheme.titleLarge)),
                  IconButton(tooltip: '刷新', onPressed: controller.reload, icon: const Icon(Icons.refresh)),
                ],
              ),
              if (controller.jobs.isEmpty && !controller.loading)
                const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Text('还没有导入任务。')),
              for (final job in controller.jobs.take(100))
                _ImportJobCard(controller: controller, job: job, onReaderRequested: onReaderRequested),
              const Divider(height: 36),
              Row(
                children: <Widget>[
                  Expanded(child: Text('书库', style: Theme.of(context).textTheme.titleLarge)),
                  Text('占用 ${_formatBytes(controller.usageBytes)}'),
                  IconButton(
                    tooltip: '清理未引用的本地文件',
                    onPressed: controller.loading
                        ? null
                        : () async {
                            try {
                              final freed = await controller.collectGarbage();
                              if (context.mounted) {
                                ScaffoldMessenger.of(
                                  context,
                                ).showSnackBar(SnackBar(content: Text(freed == 0 ? '没有可清理的文件。' : '已清理 ${_formatBytes(freed)} 未引用文件。')));
                              }
                            } on Object catch (error) {
                              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('清理失败：$error')));
                            }
                          },
                    icon: const Icon(Icons.cleaning_services_outlined),
                  ),
                ],
              ),
              if (controller.documents.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Text('尚无本地书籍。')),
              for (final item in controller.documents)
                ListTile(
                  key: ValueKey<String>('local-${item.id.value}'),
                  leading: const Icon(Icons.menu_book_outlined),
                  title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${item.author ?? '作者未知'} · ${item.source.isLocal ? '本地书籍' : '其他来源'}${item.state == 'retained' ? ' · 已从书架移除，内容保留' : ''}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => LocalDocumentDetailPage(itemId: item.id.value, onReaderRequested: onReaderRequested),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImportJobCard extends StatefulWidget {
  const _ImportJobCard({required this.controller, required this.job, this.onReaderRequested});
  final LocalImportController controller;
  final LocalImportSnapshot job;
  final ValueChanged<String>? onReaderRequested;
  @override
  State<_ImportJobCard> createState() => _ImportJobCardState();
}

class _ImportJobCardState extends State<_ImportJobCard> {
  late final TextEditingController _title = TextEditingController(text: widget.job.title ?? _titleFromName(widget.job.fileName));
  late final TextEditingController _author = TextEditingController(text: widget.job.author ?? '');
  @override
  void dispose() {
    _title.dispose();
    _author.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final controller = widget.controller;
    final status = switch (job.status) {
      LocalImportStatus.queued ||
      LocalImportStatus.acquiring ||
      LocalImportStatus.inspecting ||
      LocalImportStatus.parsing ||
      LocalImportStatus.validating ||
      LocalImportStatus.committing => '处理中',
      LocalImportStatus.awaitingConfirmation => '等待确认',
      LocalImportStatus.succeeded => '已完成',
      LocalImportStatus.cancelled => '已取消',
      LocalImportStatus.interrupted => '中断，可重试',
      LocalImportStatus.needsAction => '需要处理',
      LocalImportStatus.failed => '失败',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(job.fileName, style: Theme.of(context).textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 8),
                Text(status),
              ],
            ),
            if (job.totalBytes != null) Text('${_formatBytes(job.completedBytes)} / ${_formatBytes(job.totalBytes!)}'),
            if (job.workTotal case final int total when total > 0) ...<Widget>[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: ((job.workCompleted ?? 0) / total).clamp(0.0, 1.0).toDouble()),
              Text('${_workStageLabel(job.workStage)} · ${job.workCompleted ?? 0} / $total'),
            ],
            if (job.status == LocalImportStatus.awaitingConfirmation) ...<Widget>[
              const SizedBox(height: 10),
              TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: '书名', isDense: true),
                onChanged: (value) =>
                    controller.updateMetadata(job.id, title: value, author: _author.text.trim().isEmpty ? null : _author.text.trim()),
              ),
              TextField(
                controller: _author,
                decoration: const InputDecoration(labelText: '作者（可选）', isDense: true),
                onChanged: (value) =>
                    controller.updateMetadata(job.id, title: _title.text, author: value.trim().isEmpty ? null : value.trim()),
              ),
              const SizedBox(height: 10),
              if (job.format == LocalDocumentFormat.txt) ...<Widget>[
                DropdownButtonFormField<String>(
                  initialValue: (controller.options[job.id] ?? job.options).encoding ?? 'auto',
                  decoration: const InputDecoration(labelText: 'TXT 编码', isDense: true),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem(value: 'auto', child: Text('自动识别')),
                    DropdownMenuItem(value: 'utf-8', child: Text('UTF-8')),
                    DropdownMenuItem(value: 'gb18030', child: Text('GB18030 / GBK')),
                    DropdownMenuItem(value: 'utf-16le', child: Text('UTF-16 LE')),
                    DropdownMenuItem(value: 'utf-16be', child: Text('UTF-16 BE')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    final old = controller.options[job.id] ?? job.options;
                    controller.setOptions(
                      job.id,
                      LocalDocumentParseOptions(
                        encoding: value == 'auto' ? null : value,
                        chapterRule: old.chapterRule,
                        allowMalformed: old.allowMalformed,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: (controller.options[job.id] ?? job.options).chapterRule,
                  decoration: const InputDecoration(labelText: '章节识别', isDense: true),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem(value: 'auto', child: Text('自动识别')),
                    DropdownMenuItem(value: 'chinese', child: Text('中文章节')),
                    DropdownMenuItem(value: 'english', child: Text('英文章节')),
                    DropdownMenuItem(value: 'none', child: Text('整书一章')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    final old = controller.options[job.id] ?? job.options;
                    controller.setOptions(
                      job.id,
                      LocalDocumentParseOptions(encoding: old.encoding, chapterRule: value, allowMalformed: old.allowMalformed),
                    );
                  },
                ),
              ],
              if ((controller.covers[job.id]?.isNotEmpty ?? false)) ...<Widget>[
                const SizedBox(height: 10),
                Center(
                  child: LocalDocumentImage(controller.covers[job.id]!, height: 160, fit: BoxFit.contain, fallback: const Text('封面无法预览')),
                ),
              ],
              for (var i = 0; i < (controller.previews[job.id]?.length ?? 0); i++)
                ExpansionTile(
                  title: Text('正文预览 ${i + 1}'),
                  children: <Widget>[
                    Padding(padding: const EdgeInsets.all(12), child: SelectableText(controller.previews[job.id]![i], maxLines: 14)),
                  ],
                ),
              Wrap(
                spacing: 8,
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: () => controller.commit(job.id, title: _title.text, author: _author.text),
                    icon: const Icon(Icons.check),
                    label: const Text('确认导入'),
                  ),
                  TextButton(onPressed: () => controller.cancel(job.id), child: const Text('取消')),
                ],
              ),
            ],
            if ((job.status == LocalImportStatus.needsAction || job.status == LocalImportStatus.failed) &&
                (job.errorCode == 'encoding_required' ||
                    job.errorCode == 'unsupported_encoding' ||
                    job.errorCode == 'malformed_text')) ...<Widget>[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: (controller.options[job.id] ?? job.options).encoding ?? 'auto',
                decoration: const InputDecoration(labelText: 'TXT 编码', isDense: true),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem(value: 'auto', child: Text('自动识别')),
                  DropdownMenuItem(value: 'utf-8', child: Text('UTF-8')),
                  DropdownMenuItem(value: 'gb18030', child: Text('GB18030 / GBK')),
                  DropdownMenuItem(value: 'utf-16le', child: Text('UTF-16 LE')),
                  DropdownMenuItem(value: 'utf-16be', child: Text('UTF-16 BE')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  final old = controller.options[job.id] ?? job.options;
                  controller.setOptions(
                    job.id,
                    LocalDocumentParseOptions(
                      encoding: value == 'auto' ? null : value,
                      chapterRule: old.chapterRule,
                      allowMalformed: old.allowMalformed,
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: (controller.options[job.id] ?? job.options).chapterRule,
                decoration: const InputDecoration(labelText: '章节识别', isDense: true),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem(value: 'auto', child: Text('自动识别')),
                  DropdownMenuItem(value: 'chinese', child: Text('中文章节')),
                  DropdownMenuItem(value: 'english', child: Text('英文章节')),
                  DropdownMenuItem(value: 'none', child: Text('整书一章')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  final old = controller.options[job.id] ?? job.options;
                  controller.setOptions(
                    job.id,
                    LocalDocumentParseOptions(encoding: old.encoding, chapterRule: value, allowMalformed: old.allowMalformed),
                  );
                },
              ),
            ],
            if (job.format == LocalDocumentFormat.txt &&
                (job.status == LocalImportStatus.awaitingConfirmation ||
                    job.status == LocalImportStatus.failed ||
                    job.status == LocalImportStatus.needsAction))
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('用替换字符读取损坏的文本字节'),
                subtitle: const Text('仅在无法修正编码时启用，并重新检查正文预览。'),
                value: (controller.options[job.id] ?? job.options).allowMalformed,
                onChanged: (value) {
                  if (value == null) return;
                  final old = controller.options[job.id] ?? job.options;
                  controller.setOptions(
                    job.id,
                    LocalDocumentParseOptions(encoding: old.encoding, chapterRule: old.chapterRule, allowMalformed: value),
                  );
                },
              ),
            if (job.status == LocalImportStatus.succeeded && job.itemId != null)
              FilledButton.tonalIcon(
                onPressed: () => widget.onReaderRequested?.call(job.itemId!.value),
                icon: const Icon(Icons.menu_book),
                label: const Text('立即阅读'),
              ),
            if (job.status == LocalImportStatus.failed ||
                job.status == LocalImportStatus.interrupted ||
                job.status == LocalImportStatus.needsAction)
              TextButton.icon(onPressed: () => controller.retry(job.id), icon: const Icon(Icons.refresh), label: const Text('重试')),
            if (controller.errors[job.id] != null ||
                ((job.status == LocalImportStatus.failed ||
                        job.status == LocalImportStatus.needsAction ||
                        job.status == LocalImportStatus.interrupted) &&
                    job.errorCode != null))
              Text(controller.errors[job.id] ?? controller.errorLabel(job), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (job.warnings.isNotEmpty) Text('提示：${job.warnings.join('、')}'),
          ],
        ),
      ),
    );
  }
}

String _titleFromName(String name) => name.replaceFirst(RegExp(r'\.(txt|epub)$', caseSensitive: false), '');
String _formatBytes(int value) =>
    value < 1024 * 1024 ? '${(value / 1024).toStringAsFixed(0)} KiB' : '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';

String _workStageLabel(String? stage) => switch (stage) {
  'chapters' => '读取章节',
  'resources' => '读取资源',
  'validating' => '校验正文',
  'committing' => '写入书库',
  _ => '解析中',
};
