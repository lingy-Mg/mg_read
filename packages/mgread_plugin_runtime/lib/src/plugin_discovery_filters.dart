/// Immutable source filter groups and their strict wire decoder. Sources own
/// selected ids and combined targets; the host owns remote and mobile layouts.
part of mgread_plugin_runtime;

final class PluginDiscoveryFilterGroup {
  PluginDiscoveryFilterGroup({
    required this.id,
    required this.label,
    required this.selectedOptionId,
    required List<PluginDiscoveryTab> options,
  }) : options = List.unmodifiable(options);
  final String id;
  final String label;
  final String? selectedOptionId;
  final List<PluginDiscoveryTab> options;
}

final class PluginDiscoveryFiltersComponent extends PluginDiscoveryComponent {
  PluginDiscoveryFiltersComponent({
    required super.id,
    required List<PluginDiscoveryFilterGroup> groups,
    required this.resetTarget,
  }) : groups = List.unmodifiable(groups);
  final List<PluginDiscoveryFilterGroup> groups;
  final String resetTarget;
}

PluginDiscoveryFiltersComponent _decodeDiscoveryFilters(
  Map<String, Object?> item,
  String id,
) {
  const context = 'Source discovery filters';
  final rawGroups = _contentList(item, 'groups', context);
  if (rawGroups.length > 8) _contentInvalid('$context has too many groups.');
  final groups = rawGroups
      .map((value) {
        final group = _contentObject(value, context);
        final options = _contentList(
          group,
          'options',
          context,
        ).map(_decodeDiscoveryTab).toList(growable: false);
        if (options.length > 64)
          _contentInvalid('$context has too many options.');
        _requireUnique(options.map((option) => option.id), context);
        final selected = _contentNullableString(
          group,
          'selectedOptionId',
          context,
        );
        if (selected != null && !options.any((option) => option.id == selected))
          _contentInvalid('$context has an invalid selection.');
        return PluginDiscoveryFilterGroup(
          id: _contentString(group, 'id', context),
          label: _contentString(group, 'label', context),
          selectedOptionId: selected,
          options: options,
        );
      })
      .toList(growable: false);
  _requireUnique(groups.map((group) => group.id), context);
  return PluginDiscoveryFiltersComponent(
    id: id,
    groups: groups,
    resetTarget: _contentString(item, 'resetTarget', context),
  );
}
