/// Phone presentation of TV-executed source browsing. Source identities remain
/// attached to every result; TV re-resolves the selected episode at handoff.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mg_read/app/app_theme.dart';
import '../application/companion_controller.dart';
import '../domain/companion_models.dart';
import '../domain/companion_command.dart';
import 'companion_messages.dart';
import 'companion_widgets.dart';

class CompanionCatalogPage extends StatefulWidget {
  const CompanionCatalogPage({required this.service, this.embedded = false, super.key});
  final CompanionController service;
  final bool embedded;
  @override
  State<CompanionCatalogPage> createState() => _CompanionCatalogPageState();
}

class _CompanionCatalogPageState extends State<CompanionCatalogPage> {
  final _query = TextEditingController();
  List<Map<String, Object?>> _sources = [], _items = [];
  String? _source, _error, _cursor;
  bool _busy = false, _hasMore = false, _loadingSources = true, _queried = false;
  int _generation = 0;
  int? _browseOffset;
  String _method = 'search';
  @override
  void initState() {
    super.initState();
    unawaited(_sourcesLoad());
  }

  @override
  void dispose() {
    _generation++;
    _query.dispose();
    super.dispose();
  }

  Future<void> _sourcesLoad() async {
    setState(() => _loadingSources = true);
    try {
      final result = await widget.service.request('sources');
      if (mounted) {
        setState(() {
          _sources = [for (final item in result['sources'] as List) companionMap(item)];
          if (!_sources.any((source) => source['id'] == _source)) _source = null;
          _error = null;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'));
    } finally {
      if (mounted) setState(() => _loadingSources = false);
    }
  }

  Future<void> _search({bool more = false, String method = 'search'}) async {
    if (more) method = _method;
    if (!more) _method = method;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _queried = true;
      _error = null;
    });
    try {
      if (method == 'search' && _query.text.trim().isEmpty) {
        setState(() => _items = []);
        return;
      }
      final result = await widget.service.request(
        method,
        arguments: method == 'search'
            ? {'query': _query.text.trim(), if (_source != null) 'pluginId': _source, if (more && _cursor != null) 'cursor': _cursor}
            : {'offset': more ? _browseOffset ?? 0 : 0},
      );
      if (!mounted || generation != _generation) return;
      final rows = method == 'history'
          ? [
              for (final raw in result['entries'] as List)
                {...companionMap(raw), 'positionMs': companionMap(raw)['positionMs'], 'sourceName': '观看记录'},
            ]
          : [for (final raw in result['items'] as List) companionMap(raw)];
      setState(() {
        _items = more ? [..._items, ...rows] : rows;
        _cursor = result['cursor'] as String?;
        _browseOffset = result['nextOffset'] as int?;
        _hasMore = result['hasMore'] == true || _browseOffset != null;
        if ((result['failures'] as List? ?? []).isNotEmpty) _error = '部分 TV 来源未完成查询，已保留其他结果。可选择来源重试。';
      });
    } on Object catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'));
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.compactPagePadding),
            child: CompanionPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('在手机挑选，在 TV 播放', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: AppSpacing.compact),
                  Text(
                    '使用 TV 已安装的来源搜索，找片时不会打断电视画面。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: AppSpacing.comfortable),
                  TextField(
                    controller: _query,
                    maxLength: 256,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(hintText: '搜索电影、电视剧', prefixIcon: const Icon(Icons.search_rounded), counterText: ''),
                    onSubmitted: _busy ? null : (_) => _search(),
                  ),
                  const SizedBox(height: AppSpacing.regular),
                  DropdownButtonFormField<String>(
                    key: ValueKey(_source),
                    initialValue: _source,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'TV 影视来源', prefixIcon: Icon(Icons.extension_outlined)),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('全部影视来源')),
                      for (final source in _sources)
                        DropdownMenuItem(value: source['id'] as String, child: Text(source['label'] as String)),
                    ],
                    onChanged: _loadingSources || _busy ? null : (value) => setState(() => _source = value),
                  ),
                  const SizedBox(height: AppSpacing.regular),
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _search(),
                    icon: const Icon(Icons.search_rounded),
                    label: const Text('在 TV 来源中搜索'),
                  ),
                  const SizedBox(height: AppSpacing.compact),
                  Wrap(
                    spacing: AppSpacing.compact,
                    runSpacing: AppSpacing.compact,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => _search(method: 'favorites'),
                        icon: const Icon(Icons.bookmark_border_rounded),
                        label: const Text('TV 收藏'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => _search(method: 'history'),
                        icon: const Icon(Icons.history_rounded),
                        label: const Text('TV 观看记录'),
                      ),
                      TextButton(onPressed: _loadingSources ? null : _sourcesLoad, child: const Text('刷新来源')),
                      if (_busy)
                        TextButton(
                          onPressed: () {
                            _generation++;
                            widget.service.cancelSearch();
                            setState(() => _busy = false);
                          },
                          child: const Text('取消搜索'),
                        ),
                    ],
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: AppSpacing.compact),
                      child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  if (_busy || _loadingSources) const LinearProgressIndicator(),
                  if (!_loadingSources && _sources.isEmpty && _error == null)
                    const Padding(
                      padding: EdgeInsets.only(top: AppSpacing.compact),
                      child: Text('TV 暂无可用影视来源，请先在电视上安装或启用数据源。'),
                    ),
                ],
              ),
            ),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            if (index == _items.length) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: _cursor != null || _browseOffset != null
                    ? TextButton(onPressed: _busy ? null : () => _search(more: true), child: const Text('加载更多'))
                    : _items.isEmpty && !_busy
                    ? Column(
                        children: [
                          Icon(
                            _queried ? Icons.search_off_rounded : Icons.movie_filter_outlined,
                            size: 44,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: AppSpacing.regular),
                          Text(_queried ? '暂无匹配内容' : '下一部想看什么？', style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: AppSpacing.compact),
                          Text(
                            _queried ? '试试其他关键词或来源，也可查看 TV 收藏。' : '输入片名搜索，或从 TV 收藏和观看记录中挑选。',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      )
                    : Text(_hasMore ? '聚合结果较多，可选择单个来源继续分页。' : ''),
              );
            }
            final item = _items[index];
            final variants = item['variants'] as List?;
            return Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.compactPagePadding, 0, AppSpacing.compactPagePadding, AppSpacing.compact),
              child: CompanionPanel(
                padding: 0,
                child: ListTile(
                  contentPadding: const EdgeInsets.all(AppSpacing.regular),
                  shape: const RoundedRectangleBorder(borderRadius: AppRadii.card),
                  leading: Icon(Icons.movie_outlined, color: Theme.of(context).colorScheme.primary),
                  title: Text(item['title'] as String),
                  subtitle: Text(
                    '${item['sourceName'] ?? item['pluginId']}${variants != null && variants.length > 1 ? ' · ${variants.length} 个来源版本' : ''}',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _detail(item),
                ),
              ),
            );
          }, childCount: _items.length + 1),
        ),
      ],
    );
    return widget.embedded
        ? body
        : Scaffold(
            appBar: AppBar(title: const Text('搜索 TV 来源')),
            body: body,
          );
  }

  Future<void> _detail(Map<String, Object?> item) async {
    final variants = item['variants'] as List?;
    var selected = item;
    if (variants != null && variants.length > 1) {
      var choices = [for (final raw in variants) companionMap(raw)];
      var hasMore = (item['variantCount'] as int? ?? choices.length) > choices.length;
      while (mounted) {
        final choice = await showDialog<Object>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('选择来源'),
            children: [
              for (final raw in choices)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, companionMap(raw)),
                  child: Text(companionMap(raw)['sourceName'] as String),
                ),
              if (hasMore) SimpleDialogOption(onPressed: () => Navigator.pop(context, 'more'), child: const Text('更多来源')),
            ],
          ),
        );
        if (choice == null) return;
        if (choice == 'more') {
          try {
            final result = await widget.service.request('variants', arguments: {'resultKey': item['resultKey'], 'offset': choices.length});
            choices = [...choices, for (final raw in result['items'] as List) companionMap(raw)];
            hasMore = result['nextOffset'] != null;
          } on Object catch (error) {
            if (mounted) setState(() => _error = companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'));
            return;
          }
          continue;
        }
        selected = companionMap(choice);
        break;
      }
    }
    if (mounted) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => _TvContentDetail(service: widget.service, item: selected),
        ),
      );
    }
  }
}

class _TvContentDetail extends StatefulWidget {
  const _TvContentDetail({required this.service, required this.item});
  final CompanionController service;
  final Map<String, Object?> item;
  @override
  State<_TvContentDetail> createState() => _TvContentDetailState();
}

class _TvContentDetailState extends State<_TvContentDetail> {
  Map<String, Object?>? _detail;
  List<Map<String, Object?>> _groups = [], _episodes = [];
  String? _group, _error;
  int? _offset;
  int? _groupOffset;
  int _generation = 0;
  bool _busy = false, _sending = false, _useTvProgress = true;
  Map<String, Object?> get _base => {'pluginId': widget.item['pluginId'], 'contentId': widget.item['contentId']};
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.service.request('detail', arguments: _base),
        widget.service.request('catalog', arguments: _base),
      ]);
      if (!mounted || generation != _generation) return;
      setState(() {
        _detail = results[0];
        _groups = [for (final raw in results[1]['groups'] as List) companionMap(raw)];
        _groupOffset = results[1]['nextOffset'] as int?;
        _group = widget.item['groupId'] as String? ?? (_groups.firstOrNull?['id'] as String?);
      });
      if (_group != null) await _loadEpisodes();
    } on Object catch (error) {
      if (mounted) setState(() => _error = companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadEpisodes({bool more = false}) async {
    final generation = ++_generation;
    final group = _group;
    if (group == null) return;
    setState(() => _busy = true);
    try {
      final result = await widget.service.request('episodes', arguments: {..._base, 'groupId': group, 'offset': more ? _offset ?? 0 : 0});
      if (!mounted || generation != _generation) return;
      final episodes = [for (final raw in result['items'] as List) companionMap(raw)];
      setState(() {
        _episodes = more ? [..._episodes, ...episodes] : episodes;
        _offset = result['nextOffset'] as int?;
      });
    } on Object catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'));
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _moreGroups() async {
    if (_groupOffset == null) return;
    setState(() => _busy = true);
    try {
      final result = await widget.service.request('catalog', arguments: {..._base, 'offset': _groupOffset});
      if (mounted) {
        setState(() {
          _groups = [..._groups, for (final raw in result['groups'] as List) companionMap(raw)];
          _groupOffset = result['nextOffset'] as int?;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.item['title'] as String)),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (_busy || _sending) const LinearProgressIndicator(),
        if (_detail != null) Text(_detail!['description'] as String? ?? ''),
        if (_error != null) ...[Text(_error!), TextButton(onPressed: _load, child: const Text('重试'))],
        if (_groups.isNotEmpty)
          DropdownButtonFormField<String>(
            key: ValueKey(_group),
            initialValue: _group,
            decoration: const InputDecoration(labelText: '分组 / 线路'),
            items: [for (final group in _groups) DropdownMenuItem(value: group['id'] as String, child: Text(group['title'] as String))],
            onChanged: _sending
                ? null
                : (value) {
                    setState(() => _group = value);
                    unawaited(_loadEpisodes());
                  },
          ),
        if (_groupOffset != null) TextButton(onPressed: _busy || _sending ? null : _moreGroups, child: const Text('更多分组 / 线路')),
        SwitchListTile(
          title: const Text('使用 TV 已保存的观看位置'),
          subtitle: const Text('关闭后从所选集开头播放；观看记录入口可接续指定位置。'),
          value: _useTvProgress,
          onChanged: _sending ? null : (value) => setState(() => _useTvProgress = value),
        ),
        for (final episode in _episodes)
          ListTile(
            title: Text(episode['title'] as String),
            trailing: const Icon(Icons.play_circle_outline),
            onTap: _sending ? null : () => _play(episode),
          ),
        if (_offset != null) TextButton(onPressed: _busy ? null : () => _loadEpisodes(more: true), child: const Text('更多选集')),
        const SizedBox(height: 16),
        const Text('TV 将自行解析所选集。若需要安装来源、登录或验证，请按 TV 提示操作；手机不会复制登录凭据。'),
      ],
    ),
  );
  Future<void> _play(Map<String, Object?> episode) async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final receipt = await widget.service.handoff(
        CompanionContentRef(
          pluginId: widget.item['pluginId'] as String,
          pluginVersion: widget.item['pluginVersion'] as String? ?? 'unknown',
          contentId: widget.item['contentId'] as String,
          title: widget.item['title'] as String,
          groupId: _group!,
          episodeId: episode['id'] as String,
          positionMs: widget.item['episodeId'] == episode['id'] ? (widget.item['positionMs'] as int? ?? 0) : 0,
          useTvProgress: _useTvProgress,
        ),
      );
      if (!mounted) return;
      if (receipt.phase == CompanionCommandPhase.started) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('TV 已实际起播，可返回遥控页操作。')));
        Navigator.pop(context);
      } else {
        setState(() => _error = companionErrorText(receipt.code));
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }
}
