/// Direct Bilibili audiobook entry embedded in Discovery.
///
/// Resolves one pasted Bilibili video URL through the installed Bilibili
/// source, shows its full multipart catalog, and hands episode playback to the
/// host audio player. The page owns only input and transient loading state.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_sheet.dart';

const bilibiliAudioSourceId = 'org.mgread.bilibili-audio';

final class BilibiliUrlPlaybackPage extends StatefulWidget {
  const BilibiliUrlPlaybackPage({required this.onAudioChapterRequested, super.key});

  final SourceAudioChapterRequested onAudioChapterRequested;

  @override
  State<BilibiliUrlPlaybackPage> createState() => _BilibiliUrlPlaybackPageState();
}

final class _BilibiliUrlPlaybackPageState extends State<BilibiliUrlPlaybackPage> {
  final TextEditingController _urlController = TextEditingController();
  PluginContentDetail? _detail;
  PluginChaptersResult? _catalog;
  Object? _error;
  bool _loading = false;
  String? _playingEpisodeId;
  String? _pluginVersion;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final bvid = _extractBvid(_urlController.text.trim());
    if (bvid == null) {
      setState(() {
        _detail = null;
        _catalog = null;
        _error = const FormatException('请输入有效的 B 站视频链接或 BV 号。');
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _detail = null;
      _catalog = null;
    });
    try {
      final gateway = ProviderScope.containerOf(context, listen: false).read(sourceContentGatewayProvider);
      final results = await Future.wait<Object>([
        gateway.listSources(),
        gateway.getDetail(pluginId: bilibiliAudioSourceId, id: 'bvid:$bvid'),
        gateway.getChapters(pluginId: bilibiliAudioSourceId, id: 'bvid:$bvid'),
      ]);
      if (!mounted) return;
      final sources = results[0] as List<PluginSourceDescriptor>;
      PluginSourceDescriptor? source;
      for (final candidate in sources) {
        if (candidate.id == bilibiliAudioSourceId) source = candidate;
      }
      if (source == null) throw StateError('Bilibili audio source is not enabled.');
      setState(() {
        _pluginVersion = source!.pluginVersion;
        _detail = results[1] as PluginContentDetail;
        _catalog = results[2] as PluginChaptersResult;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _play(PluginChapterSummary chapter) async {
    final detail = _detail;
    final catalog = _catalog;
    if (detail == null || catalog == null) return;
    setState(() => _playingEpisodeId = chapter.id);
    try {
      await widget.onAudioChapterRequested(
        detail: detail,
        firstCatalogPage: catalog,
        chapter: chapter,
        pluginVersion: _pluginVersion ?? 'unknown',
      );
    } on Object catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('打开音频失败：$error')));
    } finally {
      if (mounted) setState(() => _playingEpisodeId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final catalog = _catalog;
    return Scaffold(
      appBar: AppBar(title: const Text('B站链接播放')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.page),
              children: [
                TextField(
                  key: const Key('bilibili-url-input'),
                  controller: _urlController,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _load(),
                  decoration: InputDecoration(
                    labelText: 'B站音频链接或 BV 号',
                    hintText: 'https://www.bilibili.com/video/BV…',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      key: const Key('bilibili-url-submit'),
                      tooltip: '读取选集',
                      onPressed: _loading ? null : _load,
                      icon: _loading
                          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.arrow_forward_rounded),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.regular),
                  Text(
                    _error is FormatException ? (_error as FormatException).message : '读取失败，请确认已安装并启用哔哩哔哩数据源后重试。',
                    key: const Key('bilibili-url-error'),
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(onPressed: _loading ? null : _load, child: const Text('重试')),
                  ),
                ],
                if (detail != null && catalog != null) ...[
                  const SizedBox(height: AppSpacing.section),
                  Text(detail.summary.title, style: Theme.of(context).textTheme.titleLarge),
                  if (detail.summary.description?.isNotEmpty ?? false) ...[
                    const SizedBox(height: AppSpacing.unit),
                    Text(detail.summary.description!, maxLines: 4, overflow: TextOverflow.ellipsis),
                  ],
                  const SizedBox(height: AppSpacing.regular),
                  Text('音频选集（${catalog.items.length}）', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.unit),
                  for (final episode in catalog.items)
                    ListTile(
                      key: ValueKey<String>('bilibili-episode-${episode.id}'),
                      contentPadding: EdgeInsets.zero,
                      leading: Text('${episode.order + 1}'.padLeft(2, '0')),
                      title: Text(episode.title),
                      trailing: _playingEpisodeId == episode.id
                          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.play_arrow_rounded),
                      onTap: _playingEpisodeId == null ? () => _play(episode) : null,
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String? _extractBvid(String value) {
  final match = RegExp(r'(?<![A-Za-z0-9])BV[1-9A-HJ-NP-Za-km-z]{10}(?![A-Za-z0-9])', caseSensitive: false).firstMatch(value);
  if (match == null) return null;
  final candidate = match.group(0);
  if (candidate == null || !candidate.startsWith('BV')) return null;
  return candidate;
}
