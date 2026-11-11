/// Portable source filters. TV exposes the first group as secondary navigation
/// and keeps the remaining conditions in an OK-operated modal. That modal reads
/// current immutable discovery snapshots, so each choice preserves the source's
/// combined targets after another condition loads. No IO runs in this widget.
library;

import 'package:mg_read/shared/presentation/motion/app_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import '../../application/discovery_page_controller.dart';
import '../../application/discovery_page_state.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

class DiscoveryFilters extends StatelessWidget {
  const DiscoveryFilters({required this.component, required this.pluginId, required this.onSelected, super.key});
  final PluginDiscoveryFiltersComponent component;
  final String pluginId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final groups = component.groups;
    if (groups.isEmpty) return const SizedBox.shrink();
    final tv = TvModeScope.isEnabled(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (tv) ...[
          _FilterRow(group: groups.first, onSelected: onSelected, activateOnFocus: true),
          if (groups.length > 1) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TvFocusable(
                  key: const Key('tv-open-filters'),
                  onPressed: () => showDialog<void>(
                    context: context,
                    animationStyle: AppMotion.overlayStyle(context),
                    builder: (_) => _FilterDialog(initial: component, pluginId: pluginId, onSelected: onSelected),
                  ),
                  child: const Text('筛选'),
                ),
                TvFocusable(
                  key: const Key('tv-reset-filters'),
                  onPressed: () => onSelected(component.resetTarget),
                  child: const Text('重置'),
                ),
                Text(_summary(groups.skip(1)), style: Theme.of(context).textTheme.bodyLarge),
              ],
            ),
          ],
        ] else ...[
          for (final group in groups) _FilterRow(group: group, onSelected: onSelected),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () => onSelected(component.resetTarget), child: const Text('重置筛选')),
          ),
        ],
      ],
    );
  }
}

String _summary(Iterable<PluginDiscoveryFilterGroup> groups) {
  final selected = <String>[];
  for (final group in groups) {
    final option = group.options.where((option) => option.id == group.selectedOptionId).firstOrNull;
    if (option != null && option.id != group.options.firstOrNull?.id) selected.add('${group.label}：${option.label}');
  }
  return selected.isEmpty ? '全部条件' : selected.join(' · ');
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({required this.group, required this.onSelected, this.activateOnFocus = false, this.autofocus = false, super.key});
  final PluginDiscoveryFilterGroup group;
  final ValueChanged<String> onSelected;
  final bool activateOnFocus;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(group.label, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final option in group.options)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: TvModeScope.isEnabled(context)
                      ? TvFocusable(
                          key: ValueKey(('discovery-filter', group.id, option.id)),
                          selected: option.id == group.selectedOptionId,
                          autofocus: autofocus && option.id == group.selectedOptionId,
                          activateOnFocus: activateOnFocus,
                          onPressed: () => onSelected(option.target),
                          child: Text(option.label, style: Theme.of(context).textTheme.titleMedium),
                        )
                      : ChoiceChip(
                          label: Text(option.label),
                          selected: option.id == group.selectedOptionId,
                          onSelected: (_) => onSelected(option.target),
                        ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _FilterDialog extends ConsumerWidget {
  const _FilterDialog({required this.initial, required this.pluginId, required this.onSelected});
  final PluginDiscoveryFiltersComponent initial;
  final String pluginId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(discoveryPageControllerProvider);
    final document = state.result ?? state.previousResult ?? state.retainedParents.lastOrNull;
    final current = document?.pluginId == pluginId ? _findFilters(document!.document.components, initial.id) ?? initial : initial;
    final busy = state.status == DiscoveryPageStatus.loadingContent;
    void select(String target) {
      if (!busy) onSelected(target);
    }

    return AlertDialog(
      key: const Key('tv-filter-dialog'),
      constraints: const BoxConstraints(maxWidth: 1100),
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      title: const Text('筛选'),
      content: SizedBox(
        width: 1000,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (busy) const LinearProgressIndicator(),
              if (state.error != null) const Text('筛选加载失败，请重新选择或关闭后重试。'),
              for (var i = 1; i < current.groups.length; i++)
                _FilterRow(key: ValueKey(current.groups[i].id), group: current.groups[i], onSelected: select, autofocus: i == 1),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => select(current.resetTarget), child: const Text('重置全部')),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('完成')),
      ],
    );
  }
}

PluginDiscoveryFiltersComponent? _findFilters(List<PluginDiscoveryComponent> components, String id) {
  for (final component in components) {
    if (component is PluginDiscoveryFiltersComponent && component.id == id) return component;
    final children = switch (component) {
      PluginDiscoverySectionComponent(:final children) || PluginDiscoveryGroupComponent(:final children) => children,
      _ => const <PluginDiscoveryComponent>[],
    };
    final result = _findFilters(children, id);
    if (result != null) return result;
  }
  return null;
}
