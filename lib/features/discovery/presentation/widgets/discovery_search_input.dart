/// Source-declared inline discovery search, including URL resolution.
/// Owns transient input/results and cancels requests when edited or disposed;
/// content identity and opening remain with the normal source detail flow.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'discovery_content_list_item.dart';

class DiscoverySearchInput extends ConsumerStatefulWidget {
  const DiscoverySearchInput({
    required this.pluginId,
    required this.component,
    required this.onContentPressed,
    required this.isInBookshelf,
    super.key,
  });

  final String pluginId;
  final PluginDiscoverySearchInputComponent component;
  final ValueChanged<PluginContentSummary> onContentPressed;
  final bool Function(PluginContentSummary) isInBookshelf;

  @override
  ConsumerState<DiscoverySearchInput> createState() => _DiscoverySearchInputState();
}

class _DiscoverySearchInputState extends ConsumerState<DiscoverySearchInput> {
  final _input = TextEditingController();
  PluginInvocationCancellation? _request;
  List<PluginContentSummary>? _items;
  AppError? _error;
  bool _loading = false;

  void _clear() {
    _request?.cancel();
    _request = null;
    _items = null;
    _error = null;
    _loading = false;
  }

  @override
  void didUpdateWidget(covariant DiscoverySearchInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pluginId != widget.pluginId || oldWidget.component.id != widget.component.id) {
      _clear();
      _input.clear();
    }
  }

  @override
  void dispose() {
    _request?.cancel();
    _input.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final query = _input.text.trim();
    if (query.isEmpty || _loading) return;
    final request = PluginInvocationCancellation();
    setState(() {
      _clear();
      _request = request;
      _loading = true;
    });
    try {
      final gateway = ref.read(sourceContentGatewayProvider);
      final result = await runCancellableSourceRequest(gateway, request, () => gateway.search(pluginId: widget.pluginId, query: query));
      if (!mounted || _request != request) return;
      setState(() {
        _items = result.items;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || _request != request) return;
      setState(() {
        _error = AppError.fromUnknown(error);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final component = widget.component;
    final error = _error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: ValueKey('discovery-input-${component.id}'),
          controller: _input,
          textInputAction: TextInputAction.search,
          maxLength: 2000,
          onChanged: (_) => setState(_clear),
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: component.label,
            hintText: component.placeholder,
            counterText: '',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: AppSpacing.compact),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: ValueKey('discovery-input-submit-${component.id}'),
            onPressed: _loading || _input.text.trim().isEmpty ? null : _submit,
            icon: _loading
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.search_rounded),
            label: Text(component.submitLabel),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: AppSpacing.compact),
          Text(
            '${_errorMessage(error)}\n${error.detail ?? error.code.wireValue}',
            key: ValueKey('discovery-input-error-${component.id}'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: _submit, child: const Text('重试')),
          ),
        ],
        if (_items?.isEmpty ?? false) const Text('没有找到内容，请检查输入后重试。'),
        for (final content in _items ?? const <PluginContentSummary>[]) ...[
          const SizedBox(height: AppSpacing.regular),
          DiscoveryContentListItem(
            item: PluginDiscoveryContentItem(content: content, rank: null, metric: null, recommendation: null),
            variant: DiscoveryCoverVariant.indigo,
            keyPrefix: 'discovery-input-result-${component.id}',
            isInBookshelf: widget.isInBookshelf(content),
            onPressed: () => widget.onContentPressed(content),
          ),
        ],
      ],
    );
  }
}

String _errorMessage(AppError error) => switch (error.code) {
  AppErrorCode.sourceAccessBlocked || AppErrorCode.interactionRequired => '网站拒绝了当前访问，请稍后重试。',
  AppErrorCode.pluginNotFound || AppErrorCode.pluginDisabled || AppErrorCode.pluginDamaged => '当前数据源不可用，请在数据源管理中检查。',
  AppErrorCode.timeout => '读取超时，请重试。',
  _ => '读取失败，请检查输入或稍后重试。',
};
