part of mgread_plugin_runtime;

/// Resolves saved resources against their enabled owner without exposing routes.
/// A host preference affects the returned descriptor, never stored source data.
/// Supporting HLS owners supply fallback policy for true, remove source policy
/// for false, and preserve existing policy for null. Unsupported owners and
/// remote HTTP resources preserve their original behavior.
@immutable
final class SourceResourceResolveInvocation extends PluginInvocation<String> {
  const SourceResourceResolveInvocation({
    required this.url,
    this.filterVideoAds,
  });

  final String url;
  final bool? filterVideoAds;

  @override
  String get _wireMethod => 'runtime.sourceResource.resolve.v1';

  @override
  Map<String, Object?> get _wireParams => {
    'url': url,
    if (filterVideoAds != null) 'filterVideoAds': filterVideoAds,
  };

  @override
  String _decodeResult(Object? value) {
    final result = _jsonObject(value, 'Resolved source resource');
    final resolved = result['url'];
    final route = resolved is String
        ? _SourceResourceUrl.parse(resolved)
        : null;
    final original = _SourceResourceUrl.require(url);
    if (resolved is! String ||
        route == null ||
        route.pluginId != original.pluginId ||
        route.engine != original.engine) {
      throw const PluginRuntimeException(
        'invalid_response',
        'Invalid resolved resource URL.',
      );
    }
    return resolved;
  }
}
