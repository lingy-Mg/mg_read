part of mgread_plugin_runtime;

/// Shared Node/native resource descriptor parser. Descriptors survive a worker
/// restart; their old port is never authority. Resolve through the owner before
/// fetching. Base64 is encoding, not encryption or a bearer credential.
final class _SourceResourceUrl {
  const _SourceResourceUrl(this.uri, this.engine, this.pluginId, this.request);
  final Uri uri;
  final PluginEngine engine;
  final String pluginId;
  final Map<String, Object?> request;
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
    if (parts.length != 3 ||
        parts[0] != 'v1' ||
        parts[1] != 'source-resource' ||
        parts[2].length > 24576)
      return null;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[2]))),
      );
      if (payload is! Map ||
          payload['version'] != 1 ||
          payload['pluginId'] is! String ||
          !_identity.hasMatch(payload['pluginId'] as String) ||
          payload['request'] is! Map)
        return null;
      final engine = payload['engine'];
      if (engine != null && engine != 'native' && engine != 'node') return null;
      return _SourceResourceUrl(
        uri,
        engine == 'native' ? PluginEngine.native : PluginEngine.node,
        payload['pluginId'] as String,
        Map<String, Object?>.from(payload['request'] as Map),
      );
    } on Object {
      return null;
    }
  }

  static _SourceResourceUrl require(String value) =>
      parse(value) ??
      (throw const PluginRuntimeException(
        'invalid_request',
        'Invalid source-resource URL.',
      ));
}

final class _NativePluginEndpoint {
  const _NativePluginEndpoint(this.port, this.generation, this.controlToken);
  final int port;
  final String generation;
  final String controlToken;
}

/// Only authenticated worker initialization can register endpoints. Content URLs
/// must use that port and owner; previously saved descriptors are explicitly
/// rebased by the resolve capability, never trusted as current endpoints.
final class _NativeResourceEndpoints {
  final Map<String, _NativePluginEndpoint> _entries = {};
  void clear() => _entries.clear();
  _NativePluginEndpoint register(Object? raw, String owner) {
    final data = _nativeObject(raw, 'native initialization');
    final id = data['pluginId'],
        generation = data['generation'],
        port = data['port'],
        token = data['controlToken'];
    if (id != owner ||
        generation is! String ||
        !_SourceResourceUrl._hex.hasMatch(generation) ||
        token is! String ||
        token.length < 32 ||
        port is! int ||
        port < 1 ||
        port > 65535)
      _invalid();
    final previous = _entries[owner];
    if (previous != null &&
        (previous.port != port ||
            previous.generation != generation ||
            previous.controlToken != token))
      _invalid();
    return _entries[owner] = _NativePluginEndpoint(port, generation, token);
  }

  void validate(String url, String? pluginId) {
    final route = _SourceResourceUrl.parse(url);
    final endpoint = route == null ? null : _entries[route.pluginId];
    if (route == null ||
        route.engine != PluginEngine.native ||
        route.uri.host != '127.0.0.1' ||
        endpoint == null ||
        route.pluginId != pluginId ||
        endpoint.port != route.uri.port)
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
                        value.containsKey('resourceType') ||
                        value.containsKey('index'))) ||
                child.contains('/v1/source-resource/'))) {
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
