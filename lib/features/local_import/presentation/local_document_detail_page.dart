/// Local document metadata, reparse and retention controls. All original-file
/// export and cover reads go through ContentLibrary streams, never disk paths.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/shared/presentation/widgets/local_document_image.dart';
import '../application/local_import_controller.dart';
import '../data/local_import_ingress.dart';
import 'local_import_page.dart';

class LocalDocumentDetailPage extends ConsumerStatefulWidget {
  const LocalDocumentDetailPage({required this.itemId, this.onReaderRequested, super.key});
  final String itemId;
  final ValueChanged<String>? onReaderRequested;
  @override
  ConsumerState<LocalDocumentDetailPage> createState() => _LocalDocumentDetailPageState();
}

class _LocalDocumentDetailPageState extends ConsumerState<LocalDocumentDetailPage> {
  LocalDocumentDetails? _details;
  List<int>? _cover;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final library = await ref.read(localContentLibraryProvider)();
      final id = LibraryItemId(widget.itemId);
      final details = await library.localDocumentDetails(id);
      if (details == null) throw const LocalDocumentException('item_missing');
      final cover = await library.readLocalDocumentCover(id);
      if (!mounted) return;
      setState(() {
        _details = details;
        _cover = cover;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _details;
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地书籍详情'),
        actions: <Widget>[IconButton(tooltip: '刷新', onPressed: _load, icon: const Icon(Icons.refresh))],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : detail == null
          ? const Center(child: Text('找不到这本书。'))
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: <Widget>[
                    if (_cover?.isNotEmpty ?? false)
                      Center(
                        child: LocalDocumentImage(_cover!, height: 220, fit: BoxFit.contain, fallback: const SizedBox.shrink()),
                      ),
                    Text(detail.item.title, style: Theme.of(context).textTheme.headlineSmall),
                    Text(detail.item.author ?? '作者未知'),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        Chip(label: Text(detail.format.name.toUpperCase())),
                        Chip(label: Text('${detail.chapterCount} 章')),
                        Chip(label: Text(_formatBytes(detail.originalBytes))),
                        if (detail.encoding != null) Chip(label: Text(detail.encoding!)),
                        if (detail.item.state == 'retained') const Chip(label: Text('内容保留中')),
                      ],
                    ),
                    if (detail.warnings.isNotEmpty)
                      Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('解析提示：${detail.warnings.join('、')}')),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => widget.onReaderRequested?.call(widget.itemId),
                      icon: const Icon(Icons.menu_book),
                      label: const Text('开始阅读'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(onPressed: _editMetadata, icon: const Icon(Icons.edit_outlined), label: const Text('编辑书名和作者')),
                    OutlinedButton.icon(onPressed: _reparse, icon: const Icon(Icons.refresh), label: const Text('重新解析')),
                    OutlinedButton.icon(
                      onPressed: _updateFile,
                      icon: const Icon(Icons.drive_file_rename_outline),
                      label: const Text('用新文件替换'),
                    ),
                    OutlinedButton.icon(onPressed: _replaceCover, icon: const Icon(Icons.image_outlined), label: const Text('更换封面')),
                    OutlinedButton.icon(onPressed: _restorePrevious, icon: const Icon(Icons.history), label: const Text('恢复上一版本')),
                    OutlinedButton.icon(
                      onPressed: _exportOriginal,
                      icon: const Icon(Icons.file_download_outlined),
                      label: const Text('导出原文件'),
                    ),
                    const Divider(height: 28),
                    Text('移出书架时可以保留正文，之后仍能从本地书库恢复阅读。', style: Theme.of(context).textTheme.bodySmall),
                    OutlinedButton.icon(
                      onPressed: _removeKeep,
                      icon: const Icon(Icons.inventory_2_outlined),
                      label: const Text('从书架移除并保留内容'),
                    ),
                    TextButton.icon(onPressed: _removeAll, icon: const Icon(Icons.delete_outline), label: const Text('删除书籍和未引用的本地文件')),
                  ],
                ),
              ),
            ),
    );
  }

  Future<void> _editMetadata() async {
    final detail = _details!;
    final title = TextEditingController(text: detail.item.title);
    final author = TextEditingController(text: detail.item.author ?? '');
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑书籍信息'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: title,
              autofocus: true,
              decoration: const InputDecoration(labelText: '书名'),
            ),
            TextField(
              controller: author,
              decoration: const InputDecoration(labelText: '作者'),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
        ],
      ),
    );
    if (save == true) {
      try {
        await (await ref.read(localContentLibraryProvider)()).updateLocalDocumentMetadata(
          LibraryItemId(widget.itemId),
          title: title.text,
          author: author.text.trim().isEmpty ? null : author.text.trim(),
        );
        await _load();
        if (mounted) await ref.read(localImportControllerProvider).reload();
      } on Object catch (error) {
        _show(error.toString());
      }
    }
    title.dispose();
    author.dispose();
  }

  Future<void> _reparse() async {
    try {
      final lib = await ref.read(localContentLibraryProvider)();
      final job = await lib.reparseLocalDocument(LibraryItemId(widget.itemId), _details!.options);
      await ref.read(localImportControllerProvider).reload();
      if (!mounted) return;
      _show(job.status == LocalImportStatus.awaitingConfirmation ? '新解析已就绪，请预览并确认后应用。' : '重新解析未能完成。');
      if (job.status == LocalImportStatus.awaitingConfirmation) {
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => LocalImportPage(onReaderRequested: widget.onReaderRequested)));
        if (mounted) await _load();
      }
    } on Object catch (error) {
      _show(error.toString());
    }
  }

  Future<void> _replaceCover() async {
    final selected = await LocalImportIngress.instance.pickImages();
    if (selected.isEmpty) return;
    final input = selected.first;
    final bytes = await input.openRead().fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    if (bytes.length > 8 * 1024 * 1024) {
      _show('封面最大支持 8 MiB');
      return;
    }
    try {
      final mime = input.fileName.toLowerCase().endsWith('.png')
          ? 'image/png'
          : input.fileName.toLowerCase().endsWith('.webp')
          ? 'image/webp'
          : 'image/jpeg';
      await (await ref.read(
        localContentLibraryProvider,
      )()).updateLocalDocumentCover(LibraryItemId(widget.itemId), bytes: bytes, mimeType: mime);
      await _load();
      if (mounted) await ref.read(localImportControllerProvider).reload();
    } on Object catch (error) {
      _show(error.toString());
    }
  }

  Future<void> _updateFile() async {
    final selected = await LocalImportIngress.instance.pickDocuments();
    if (selected.isEmpty) return;
    try {
      final job = await (await ref.read(
        localContentLibraryProvider,
      )()).prepareLocalImport(selected.first, replaceItemId: LibraryItemId(widget.itemId), options: _details!.options);
      await ref.read(localImportControllerProvider).reload();
      if (!mounted) return;
      if (job.status == LocalImportStatus.awaitingConfirmation) {
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => LocalImportPage(onReaderRequested: widget.onReaderRequested)));
        if (mounted) await _load();
      } else {
        _show('无法读取所选文件：${job.errorCode ?? job.status.name}');
      }
    } on Object catch (error) {
      _show(error.toString());
    }
  }

  Future<void> _restorePrevious() async {
    try {
      final job = await (await ref.read(localContentLibraryProvider)()).restorePreviousLocalDocument(LibraryItemId(widget.itemId));
      await ref.read(localImportControllerProvider).reload();
      _show(job.status == LocalImportStatus.awaitingConfirmation ? '上一版本已准备好，请在任务卡片中预览并确认。' : '无法恢复上一版本。');
    } on Object catch (error) {
      _show(error.toString());
    }
  }

  Future<void> _exportOriginal() async {
    try {
      final detail = _details!;
      if (Platform.isAndroid) {
        final name = '${detail.item.title}.${detail.format.name}';
        final mimeType = detail.format == LocalDocumentFormat.epub ? 'application/epub+zip' : 'text/plain';
        final token = await LocalImportIngress.instance.createExport(fileName: name, mimeType: mimeType);
        if (token == null) return;
        var succeeded = false;
        try {
          final library = await ref.read(localContentLibraryProvider)();
          await for (final chunk in library.openLocalDocumentOriginal(LibraryItemId(widget.itemId))) {
            var offset = 0;
            while (offset < chunk.length) {
              final end = (offset + 256 * 1024).clamp(0, chunk.length);
              await LocalImportIngress.instance.writeExportChunk(token, Uint8List.fromList(chunk.sublist(offset, end)));
              offset = end;
            }
          }
          succeeded = true;
        } finally {
          await LocalImportIngress.instance.finishExport(token, success: succeeded);
        }
        _show('原文件已导出。');
        return;
      }
      final destination = await getSaveLocation(suggestedName: '${detail.item.title}.${detail.format.name}');
      if (destination == null) return;
      final sink = File(destination.path).openWrite();
      try {
        await for (final chunk in (await ref.read(localContentLibraryProvider)()).openLocalDocumentOriginal(LibraryItemId(widget.itemId))) {
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      _show('原文件已导出。');
    } on Object catch (error) {
      _show(error.toString());
    }
  }

  Future<void> _removeKeep() => _remove(LibraryRemovalPolicy.removeFromShelfKeepContent, '已从书架移除，正文仍保留在本地书库中。');
  Future<void> _removeAll() => _remove(LibraryRemovalPolicy.removeIncludingUnreferencedContent, '书籍和未引用的内容已删除。');
  Future<void> _remove(LibraryRemovalPolicy policy, String message) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除？'),
        content: Text(policy == LibraryRemovalPolicy.removeFromShelfKeepContent ? '书籍会从当前书架隐藏，原文件和阅读数据会保留。' : '书籍会从书架移除，未被其他内容引用的本地数据会清理。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认')),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await (await ref.read(localContentLibraryProvider)()).removeLibraryItem(LibraryItemId(widget.itemId), policy);
      if (!mounted) return;
      await ref.read(localImportControllerProvider).reload();
      if (!mounted) return;
      _show(message);
      Navigator.of(context).pop();
    } on Object catch (error) {
      _show(error.toString());
    }
  }

  void _show(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

String _formatBytes(int value) =>
    value < 1024 * 1024 ? '${(value / 1024).toStringAsFixed(0)} KiB' : '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
