part of mgread_plugin_runtime;

/// The single parser for source-resource ownership. Parsing identifies a route;
/// native trust additionally requires the authenticated worker's live endpoint.
/// Ordinary remote URLs are not plugin routes. Node keeps its existing format.
final class _SourceResourceUrl {
  const _SourceResourceUrl(
    this.uri,
    this.engine,
    this.pluginId,
    this.generation,
  );
  final Uri uri;
  final PluginEngine engine;
  final String pluginId;
  final String? generation;
  static final _identity = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$');
  static final _hex = RegExp(r'^[a-f0-9]{64}$');

  static _SourceResourceUrl? parse(String value) {
    if (value.length > 32768) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'http' ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535 ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !const {'127.0.0.1', 'localhost', '::1'}.contains(uri.host))
      return null;
    final parts = uri.pathSegments;
    if (parts.length == 6 &&
        parts[0] == 'v2' &&
        parts[1] == 'source-resource' &&
        parts[2] == 'native' &&
        uri.host == '127.0.0.1' &&
        _identity.hasMatch(parts[3]) &&
        _hex.hasMatch(parts[4]) &&
        _hex.hasMatch(parts[5])) {
      return _SourceResourceUrl(uri, PluginEngine.native, parts[3], parts[4]);
    }
    if (parts.length == 3 &&
        parts[0] == 'v1' &&
        parts[1] == 'source-resource') {
      try {
        final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[2]))),
        );
        if (payload is Map &&
            payload['version'] == 1 &&
            payload['pluginId'] is String &&
            _identity.hasMatch(payload['pluginId'] as String) &&
            payload['request'] is Map) {
          return _SourceResourceUrl(
            uri,
            PluginEngine.node,
            payload['pluginId'] as String,
            null,
          );
        }
      } on Object {
        return null;
      }
    }
    return null;
  }

  static _SourceResourceUrl require(String value) =>
      parse(value) ??
      (throw const PluginRuntimeException(
        'invalid_request',
        'Invalid source-resource URL.',
      ));
}

/// Cleared at every worker boundary. Neither a loopback hostname nor a path
/// alone grants trust; port, plugin and generation must all match registration.
final class _NativeResourceEndpoints {
  final Map<String, ({int port, String generation})> _entries = {};
  void clear() => _entries.clear();

  void register(Object? raw) {
    if (raw == null) return;
    if (raw is! List || raw.length > 256) _invalid();
    for (final item in raw) {
      final data = _nativeObject(item, 'resource endpoint');
      final id = data['pluginId'];
      final generation = data['generation'];
      final port = data['port'];
      if (id is! String ||
          !_SourceResourceUrl._identity.hasMatch(id) ||
          generation is! String ||
          !_SourceResourceUrl._hex.hasMatch(generation) ||
          port is! int ||
          port < 1 ||
          port > 65535)
        _invalid();
      final endpoint = (port: port, generation: generation);
      if (_entries[id] != null && _entries[id] != endpoint) _invalid();
      _entries[id] = endpoint;
    }
  }

  void validate(String url, String? pluginId) {
    final route = _SourceResourceUrl.parse(url);
    final endpoint = route == null ? null : _entries[route.pluginId];
    if (route == null ||
        route.engine != PluginEngine.native ||
        endpoint == null ||
        route.pluginId != pluginId ||
        endpoint.port != route.uri.port ||
        endpoint.generation != route.generation)
      _invalid();
  }

  void validateResult(Object? value, String? pluginId, [int depth = 0]) {
    if (depth > 48) _invalid();
    if (value is Map) {
      for (final entry in value.entries) {
        final child = entry.value;
        if (child is String &&
            (entry.key == 'coverUrl' ||
                (entry.key == 'url' &&
                    (value.containsKey('resourcePolicy') ||
                        value.containsKey('index'))) ||
                child.contains('/v2/source-resource/'))) {
          validate(child, pluginId);
        } else {
          validateResult(child, pluginId, depth + 1);
        }
      }
    } else if (value is List) {
      for (final child in value) {
        validateResult(child, pluginId, depth + 1);
      }
    }
  }

  Never _invalid() => throw const PluginRuntimeException(
    'invalid_response',
    'Native resource does not belong to the active plugin instance.',
  );
}
