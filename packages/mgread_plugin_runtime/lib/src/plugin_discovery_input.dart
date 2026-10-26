/// Public inline discovery input model and strict wire decoder.
/// Sources provide labels; the host invokes source.search.v1 and owns state.
part of mgread_plugin_runtime;

/// Source-scoped inline search; the host owns input, loading and result UI.
final class PluginDiscoverySearchInputComponent
    extends PluginDiscoveryComponent {
  const PluginDiscoverySearchInputComponent({
    required super.id,
    required this.label,
    required this.placeholder,
    required this.submitLabel,
  });

  final String label;
  final String placeholder;
  final String submitLabel;
}

PluginDiscoverySearchInputComponent _decodeDiscoverySearchInput(
  Map<String, Object?> item,
  String id,
  String context,
) => PluginDiscoverySearchInputComponent(
  id: id,
  label: _contentString(item, 'label', context),
  placeholder: _contentString(item, 'placeholder', context),
  submitLabel: _contentString(item, 'submitLabel', context),
);
