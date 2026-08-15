import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_theme_mode_scope.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/search_page_controller.dart';
import 'package:mg_read/features/discovery/application/search_page_state.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_sheet.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

/// Runtime-backed search destination with explicit nullable-field rendering.
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({required this.onDestinationRequested, super.key});

  final ValueChanged<AppNavigationDestination> onDestinationRequested;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _queryController = TextEditingController();
  final FocusNode _queryFocusNode = FocusNode();

  @override
  void dispose() {
    _queryController.dispose();
    _queryFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchPageControllerProvider);
    final controller = ref.read(searchPageControllerProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        title: const Text('搜索'),
        actions: <Widget>[
          IconButton(
            key: const Key('theme-mode-toggle'),
            tooltip: Theme.of(context).brightness == Brightness.dark
                ? '切换至浅色模式'
                : '切换至深色模式',
            onPressed: () {
              AppThemeModeScope.of(
                context,
              ).onToggleTheme(Theme.of(context).brightness);
            },
            icon: Icon(
              Theme.of(context).brightness == Brightness.dark
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined,
            ),
          ),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.comfortable,
                AppSpacing.compact,
                AppSpacing.comfortable,
                0,
              ),
              child: Column(
                children: <Widget>[
                  _SearchControls(
                    state: state,
                    queryController: _queryController,
                    queryFocusNode: _queryFocusNode,
                    onSourceSelected: (pluginId) {
                      unawaited(controller.selectSource(pluginId));
                    },
                    onSearch: () {
                      _queryFocusNode.unfocus();
                      unawaited(controller.search(_queryController.text));
                    },
                    onClear: () {
                      _queryController.clear();
                      unawaited(controller.clear());
                    },
                  ),
                  const SizedBox(height: AppSpacing.comfortable),
                  Expanded(
                    child: _SearchBody(
                      state: state,
                      onContentPressed: (content) {
                        final pluginId = state.selectedSourceId;
                        if (pluginId == null) return;
                        unawaited(
                          showSourceContentDetailSheet(
                            context,
                            gateway: ref.read(sourceContentGatewayProvider),
                            pluginId: pluginId,
                            id: content.id,
                          ),
                        );
                      },
                      onRetry: () {
                        if (state.sources.isEmpty) {
                          unawaited(controller.retrySources());
                        } else {
                          unawaited(controller.search(state.query));
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: AppBottomNavigation(
          selected: AppNavigationDestination.search,
          onSelected: (destination) {
            if (destination != AppNavigationDestination.search) {
              widget.onDestinationRequested(destination);
            }
          },
        ),
      ),
    );
  }
}

class _SearchControls extends StatelessWidget {
  const _SearchControls({
    required this.state,
    required this.queryController,
    required this.queryFocusNode,
    required this.onSourceSelected,
    required this.onSearch,
    required this.onClear,
  });

  final SearchPageState state;
  final TextEditingController queryController;
  final FocusNode queryFocusNode;
  final ValueChanged<String> onSourceSelected;
  final VoidCallback onSearch;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final enabled =
        state.hasSources &&
        state.status != SearchPageStatus.loadingSources &&
        state.status != SearchPageStatus.searching;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DropdownButtonFormField<String>(
          key: ValueKey<String?>(state.selectedSourceId),
          initialValue: state.selectedSourceId,
          decoration: const InputDecoration(
            labelText: '书源',
            prefixIcon: Icon(Icons.extension_rounded),
            border: OutlineInputBorder(),
          ),
          items: state.sources
              .map(
                (source) => DropdownMenuItem<String>(
                  value: source.id,
                  child: Text(source.displayName),
                ),
              )
              .toList(growable: false),
          onChanged: enabled
              ? (value) {
                  if (value != null) onSourceSelected(value);
                }
              : null,
        ),
        const SizedBox(height: AppSpacing.regular),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const Key('source-search-query'),
                controller: queryController,
                focusNode: queryFocusNode,
                enabled: enabled,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => onSearch(),
                decoration: InputDecoration(
                  labelText: '书名、作者或关键词',
                  hintText: state.hasSources ? '输入关键词' : '请先启用书源插件',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: queryController.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清空搜索',
                          onPressed: onClear,
                          icon: const Icon(Icons.close_rounded),
                        ),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.compact),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                key: const Key('source-search-submit'),
                onPressed: enabled ? onSearch : null,
                icon: const Icon(Icons.search_rounded),
                label: const Text('搜索'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SearchBody extends StatelessWidget {
  const _SearchBody({
    required this.state,
    required this.onContentPressed,
    required this.onRetry,
  });

  final SearchPageState state;
  final ValueChanged<PluginContentSummary> onContentPressed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (state.status == SearchPageStatus.loadingSources) {
      return const _SearchMessage(
        key: Key('search-loading-sources'),
        icon: Icons.extension_rounded,
        title: '正在读取可用书源',
        loading: true,
      );
    }
    if (!state.hasSources && state.error == null) {
      return const _SearchMessage(
        key: Key('app-empty-search-page'),
        icon: Icons.extension_off_rounded,
        title: '没有可搜索的书源',
        message: '请先安装并启用支持小说或漫画内容的插件。',
      );
    }
    if (state.error != null && state.result == null) {
      return _SearchMessage(
        key: const Key('search-failure'),
        icon: Icons.error_outline_rounded,
        title: _sourceErrorTitle(state.error!),
        message: '稳定错误码：${state.error!.code.wireValue}',
        actionLabel: '重试',
        onAction: onRetry,
      );
    }
    if (state.result == null) {
      return const _SearchMessage(
        key: Key('app-empty-search-page'),
        icon: Icons.manage_search_rounded,
        title: '输入关键词开始搜索',
        message: '搜索结果会保留插件返回的书名、作者、字数、更新时间、最新章节和 URL。',
      );
    }

    final result = state.result!;
    if (result.items.isEmpty) {
      return _SearchMessage(
        key: const Key('search-empty-result'),
        icon: Icons.search_off_rounded,
        title: '没有搜索结果',
        message: '${result.sourceName} 明确返回了空数组。',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                result.sourceName,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Text(
              result.totalCount == null
                  ? '本页 ${result.items.length} 条'
                  : '共 ${result.totalCount} 条',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppThemeTokens.of(context).mutedText,
              ),
            ),
          ],
        ),
        if (state.status == SearchPageStatus.searching) ...<Widget>[
          const SizedBox(height: AppSpacing.compact),
          const LinearProgressIndicator(),
        ],
        if (state.error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.compact),
          _InlineSearchFailure(error: state.error!, onRetry: onRetry),
        ],
        const SizedBox(height: AppSpacing.compact),
        Expanded(
          child: ListView.separated(
            key: const Key('source-search-results'),
            itemCount: result.items.length,
            separatorBuilder: (_, _) =>
                const SizedBox(height: AppSpacing.compact),
            itemBuilder: (context, index) => _SearchResultCard(
              content: result.items[index],
              onPressed: () => onContentPressed(result.items[index]),
            ),
          ),
        ),
      ],
    );
  }
}

class _SearchResultCard extends StatelessWidget {
  const _SearchResultCard({required this.content, required this.onPressed});

  final PluginContentSummary content;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final metadata = <String>[
      _contentKindLabel(content.contentKind),
      if (content.author != null) '作者：${content.author}',
      if (content.wordCount != null) '字数：${content.wordCount}',
      if (content.chapterCount != null) '章节：${content.chapterCount}',
      if (content.language != null) '语言：${content.language}',
      '状态：${_statusLabel(content.status)}',
      '访问：${_accessLabel(content.access)}',
    ];
    return Card(
      key: ValueKey<String>('search-result-${content.id}'),
      margin: EdgeInsets.zero,
      color: tokens.surface,
      child: InkWell(
        onTap: onPressed,
        borderRadius: AppRadii.surface,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.comfortable),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 52,
                    height: 72,
                    decoration: BoxDecoration(
                      color: tokens.accentSoft,
                      borderRadius: AppRadii.bookCover,
                    ),
                    child: Icon(
                      content.contentKind == PluginContentKind.novel
                          ? Icons.menu_book_rounded
                          : Icons.collections_bookmark_rounded,
                      color: tokens.accent,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.regular),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(content.title, style: theme.textTheme.titleMedium),
                        const SizedBox(height: AppSpacing.unit),
                        Text(
                          '来源标识：${content.id}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: tokens.mutedText,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.regular),
              Wrap(
                spacing: AppSpacing.compact,
                runSpacing: AppSpacing.compact,
                children: metadata
                    .map((value) => Chip(label: Text(value)))
                    .toList(),
              ),
              if (content.updatedAt != null ||
                  content.publishedAt != null) ...<Widget>[
                const SizedBox(height: AppSpacing.regular),
                if (content.updatedAt != null)
                  Text('更新时间：${_formatDateTime(content.updatedAt!)}'),
                if (content.publishedAt != null)
                  Text('发布时间：${_formatDateTime(content.publishedAt!)}'),
              ],
              if (content.latestChapter != null) ...<Widget>[
                const SizedBox(height: AppSpacing.regular),
                Text(
                  '最新章节：${content.latestChapter!.title}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (content.latestChapter!.id != null)
                  Text('章节标识：${content.latestChapter!.id}'),
                if (content.latestChapter!.updatedAt != null)
                  Text(
                    '章节更新：${_formatDateTime(content.latestChapter!.updatedAt!)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: tokens.mutedText,
                    ),
                  ),
                if (content.latestChapter!.url != null)
                  _UrlField(
                    label: '章节 URL',
                    value: content.latestChapter!.url!,
                  ),
              ],
              if (content.description != null) ...<Widget>[
                const SizedBox(height: AppSpacing.regular),
                Text(content.description!, style: theme.textTheme.bodyMedium),
              ],
              if (content.categories.isNotEmpty ||
                  content.tags.isNotEmpty) ...<Widget>[
                const SizedBox(height: AppSpacing.regular),
                Wrap(
                  spacing: AppSpacing.compact,
                  runSpacing: AppSpacing.unit,
                  children: <Widget>[
                    for (final value in content.categories)
                      Chip(label: Text(value)),
                    for (final value in content.tags) Chip(label: Text(value)),
                  ],
                ),
              ],
              if (content.attributes.isNotEmpty) ...<Widget>[
                const SizedBox(height: AppSpacing.regular),
                for (final attribute in content.attributes)
                  Text('${attribute.label}：${attribute.value}'),
              ],
              if (content.url != null) ...<Widget>[
                const SizedBox(height: AppSpacing.regular),
                _UrlField(label: '内容 URL', value: content.url!),
              ],
              if (content.coverUrl != null)
                _UrlField(label: '封面 URL', value: content.coverUrl!),
            ],
          ),
        ),
      ),
    );
  }
}

class _UrlField extends StatelessWidget {
  const _UrlField({required this.label, required this.value});

  final String label;
  final Uri value;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.unit),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('$label：'),
          Expanded(
            child: SelectableText(
              value.toString(),
              style: TextStyle(color: tokens.accent),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineSearchFailure extends StatelessWidget {
  const _InlineSearchFailure({required this.error, required this.onRetry});

  final AppError error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.errorContainer,
      borderRadius: AppRadii.control,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: Row(
          children: <Widget>[
            Expanded(child: Text(_sourceErrorTitle(error))),
            TextButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

class _SearchMessage extends StatelessWidget {
  const _SearchMessage({
    required this.icon,
    required this.title,
    this.message,
    this.loading = false,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? message;
  final bool loading;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return Center(
      child: Semantics(
        liveRegion: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (loading)
              CircularProgressIndicator(color: tokens.accent)
            else
              Icon(icon, size: 48, color: tokens.mutedText),
            const SizedBox(height: AppSpacing.comfortable),
            Text(title, style: theme.textTheme.titleMedium),
            if (message != null) ...<Widget>[
              const SizedBox(height: AppSpacing.compact),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.mutedText,
                ),
              ),
            ],
            if (actionLabel != null && onAction != null) ...<Widget>[
              const SizedBox(height: AppSpacing.comfortable),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

String _contentKindLabel(PluginContentKind value) => switch (value) {
  PluginContentKind.novel => '小说',
  PluginContentKind.manga => '漫画',
};

String _statusLabel(PluginContentStatus value) => switch (value) {
  PluginContentStatus.ongoing => '连载中',
  PluginContentStatus.completed => '已完结',
  PluginContentStatus.hiatus => '暂停更新',
  PluginContentStatus.unknown => '未知',
};

String _accessLabel(PluginAccessKind value) => switch (value) {
  PluginAccessKind.free => '免费',
  PluginAccessKind.paid => '付费',
  PluginAccessKind.mixed => '部分付费',
  PluginAccessKind.unknown => '未知',
};

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}

String _sourceErrorTitle(AppError error) => switch (error.category) {
  AppErrorCategory.runtimeUnavailable => '插件运行环境不可用',
  AppErrorCategory.pluginUnavailable => '当前插件不可用',
  AppErrorCategory.incompatible => '插件或 Runtime 版本不兼容',
  AppErrorCategory.retryableTemporary => '暂时无法搜索',
  _ => '无法安全完成搜索',
};
