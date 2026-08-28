/// Windows owner for the private browser.session.v1 host boundary.
///
/// One plugin owns at most one WebView2 and isolated user-data folder. Fixed
/// host scripts implement browser fetch; direct HTTP temporarily reads the
/// profile Cookie/UA and writes Set-Cookie updates back without exposing them.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

const _maximumRequestBytes = 64 * 1024;
const _maximumResponseBytes = 2 * 1024 * 1024;
const _maximumTimeoutMs = 120000;
const _maximumPendingRequests = 16;
const _maximumResidentWebViews = 8;
const _verificationCache = Duration(minutes: 10);
const _pollDelay = Duration(milliseconds: 100);
const _interactionGrace = Duration(milliseconds: 1500);

/// Stable private-host failure consumed by the reverse Runtime bridge.
final class WindowsBrowserSessionException implements Exception {
  const WindowsBrowserSessionException(this.code);

  final String code;
}

/// Narrow native WebView2 surface. Scripts are authored only by this library.
abstract interface class WindowsBrowserPlatform {
  Future<String> create({
    required String pluginId,
    required String profilePath,
  });
  Future<void> dispose(String sessionId);
  Future<String> executeScript(String sessionId, String script);
  Future<List<Map<String, Object?>>> getCookies(String sessionId, String url);
  Future<void> hide(String sessionId);
  Future<void> load(String sessionId, String url);
  Future<void> setCookie(String sessionId, Map<String, Object?> cookie);
  Future<void> show(String sessionId);
  Future<void> stop(String sessionId);
}

/// Method-channel adapter implemented by the package's Windows plugin.
final class MethodChannelWindowsBrowserPlatform
    implements WindowsBrowserPlatform {
  const MethodChannelWindowsBrowserPlatform();

  static const _channel = MethodChannel(
    'mgread_plugin_runtime/browser_session',
  );

  @override
  Future<String> create({
    required String pluginId,
    required String profilePath,
  }) async {
    final value = await _channel.invokeMethod<String>(
      'create',
      <String, Object?>{'pluginId': pluginId, 'profilePath': profilePath},
    );
    if (value == null || value.isEmpty)
      throw const WindowsBrowserSessionException('unsupported');
    return value;
  }

  @override
  Future<void> dispose(String sessionId) => _invoke('dispose', sessionId);

  @override
  Future<String> executeScript(String sessionId, String script) async {
    final value = await _channel.invokeMethod<String>(
      'executeScript',
      <String, Object?>{'sessionId': sessionId, 'script': script},
    );
    if (value == null)
      throw const WindowsBrowserSessionException('plugin_execution_failed');
    return value;
  }

  @override
  Future<List<Map<String, Object?>>> getCookies(
    String sessionId,
    String url,
  ) async {
    final value = await _channel.invokeListMethod<Object?>(
      'getCookies',
      <String, Object?>{'sessionId': sessionId, 'url': url},
    );
    return <Map<String, Object?>>[
      for (final item in value ?? const <Object?>[])
        if (item is Map<Object?, Object?>)
          <String, Object?>{
            for (final entry in item.entries)
              if (entry.key is String) entry.key! as String: entry.value,
          },
    ];
  }

  @override
  Future<void> hide(String sessionId) => _invoke('hide', sessionId);

  @override
  Future<void> load(String sessionId, String url) =>
      _channel.invokeMethod<void>('load', <String, Object?>{
        'sessionId': sessionId,
        'url': url,
      });

  @override
  Future<void> setCookie(String sessionId, Map<String, Object?> cookie) =>
      _channel.invokeMethod<void>('setCookie', <String, Object?>{
        'sessionId': sessionId,
        'cookie': cookie,
      });

  @override
  Future<void> show(String sessionId) => _invoke('show', sessionId);

  @override
  Future<void> stop(String sessionId) => _invoke('stop', sessionId);

  Future<void> _invoke(String method, String sessionId) => _channel
      .invokeMethod<void>(method, <String, Object?>{'sessionId': sessionId});
}

/// Bounded Windows browser-session host used only by the desktop Supervisor.
final class WindowsBrowserSessionHost {
  WindowsBrowserSessionHost(
    this._dataRoot, {
    WindowsBrowserPlatform platform =
        const MethodChannelWindowsBrowserPlatform(),
    HttpClient Function()? httpClientFactory,
    DateTime Function()? clock,
  }) : _platform = platform,
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _clock = clock ?? DateTime.now;

  final Directory _dataRoot;
  final WindowsBrowserPlatform _platform;
  final HttpClient Function() _httpClientFactory;
  final DateTime Function() _clock;
  final Map<String, _WindowsBrowserJob> _jobs = <String, _WindowsBrowserJob>{};
  final Map<String, _WindowsBrowserSession> _sessions =
      <String, _WindowsBrowserSession>{};
  final Map<String, Future<_WindowsBrowserSession>> _creating =
      <String, Future<_WindowsBrowserSession>>{};
  Completer<void>? _sessionCreationGate;
  bool _disposed = false;

  Future<Map<String, Object?>> request({
    required String jobId,
    required int deadlineUnixMs,
    required Map<String, Object?> raw,
  }) async {
    if (_disposed) throw const WindowsBrowserSessionException('unsupported');
    final request = _WindowsBrowserRequest.parse(raw);
    if (_jobs.length >= _maximumPendingRequests)
      throw const WindowsBrowserSessionException('overloaded');
    final job = _WindowsBrowserJob(jobId, deadlineUnixMs, request);
    _jobs[jobId] = job;
    _WindowsBrowserSession? session;
    try {
      session = await _sessionFor(request.pluginId);
      if (session.activeJobId != null)
        throw const WindowsBrowserSessionException('overloaded');
      session.activeJobId = jobId;
      session.lastUsedAt = _clock();
      if (request.presentation == 'visible')
        await _platform.show(session.sessionId);
      final cachedAt = session.verifiedAt[request.origin];
      final cached =
          cachedAt != null &&
          _clock().difference(cachedAt) <= _verificationCache;
      final sameOrigin =
          cached && await _currentOrigin(session) == request.origin;
      final state = sameOrigin ? 'verified' : await _verify(job, session);
      return request.transport == 'webview'
          ? await _webViewFetch(job, session, state)
          : await _httpFetch(job, session, state);
    } on WindowsBrowserSessionException {
      rethrow;
    } on MissingPluginException {
      throw const WindowsBrowserSessionException('unsupported');
    } on PlatformException catch (error) {
      const allowed = <String>{
        'cancelled',
        'interaction_required',
        'overloaded',
        'plugin_execution_failed',
        'timeout',
        'unsupported',
      };
      throw WindowsBrowserSessionException(
        allowed.contains(error.code) ? error.code : 'plugin_execution_failed',
      );
    } on TimeoutException {
      throw const WindowsBrowserSessionException('timeout');
    } on Object {
      if (job.cancelled)
        throw const WindowsBrowserSessionException('cancelled');
      throw const WindowsBrowserSessionException('plugin_execution_failed');
    } finally {
      _jobs.remove(jobId);
      job.client?.close(force: true);
      if (session?.activeJobId == jobId) session!.activeJobId = null;
    }
  }

  Future<void> cancel(String jobId) async {
    final job = _jobs[jobId];
    if (job == null) return;
    job.cancelled = true;
    job.client?.close(force: true);
    final session = _sessions[job.request.pluginId];
    if (session != null) await _platform.stop(session.sessionId);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final job in _jobs.values) {
      job.cancelled = true;
      job.client?.close(force: true);
    }
    final sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    await Future.wait(<Future<void>>[
      for (final session in sessions) _platform.dispose(session.sessionId),
    ]);
  }

  Future<_WindowsBrowserSession> _sessionFor(String pluginId) async {
    final existing = _sessions[pluginId];
    if (existing != null) return existing;
    final pending = _creating[pluginId];
    if (pending != null) return pending;
    final created = _createSessionSerially(pluginId);
    _creating[pluginId] = created;
    try {
      return await created;
    } finally {
      _creating.remove(pluginId);
    }
  }

  Future<_WindowsBrowserSession> _createSessionSerially(String pluginId) async {
    while (true) {
      final pending = _sessionCreationGate;
      if (pending == null) break;
      await pending.future;
    }
    final gate = Completer<void>();
    _sessionCreationGate = gate;
    try {
      return await _createSession(pluginId);
    } finally {
      if (identical(_sessionCreationGate, gate)) _sessionCreationGate = null;
      gate.complete();
    }
  }

  Future<_WindowsBrowserSession> _createSession(String pluginId) async {
    if (_sessions.length >= _maximumResidentWebViews) {
      final idle =
          _sessions.values
              .where((session) => session.activeJobId == null)
              .toList()
            ..sort(
              (left, right) => left.lastUsedAt.compareTo(right.lastUsedAt),
            );
      if (idle.isEmpty)
        throw const WindowsBrowserSessionException('overloaded');
      final evicted = idle.first;
      _sessions.remove(evicted.pluginId);
      await _platform.dispose(evicted.sessionId);
    }
    final profile = Directory(
      '${_dataRoot.path}${Platform.pathSeparator}browser-profiles${Platform.pathSeparator}$pluginId',
    );
    await profile.create(recursive: true);
    final sessionId = await _platform.create(
      pluginId: pluginId,
      profilePath: profile.path,
    );
    final session = _WindowsBrowserSession(pluginId, sessionId, _clock());
    _sessions[pluginId] = session;
    return session;
  }

  Future<String> _verify(
    _WindowsBrowserJob job,
    _WindowsBrowserSession session,
  ) async {
    await _platform.load(session.sessionId, job.request.url);
    while (true) {
      _check(job);
      final raw = await _platform.executeScript(
        session.sessionId,
        _pageProbeScript,
      );
      final probe = _decodeScriptObject(raw);
      final ready = probe?['ready'] == true;
      final href = probe?['href'];
      final challenge = probe?['challenge'] == true;
      final sameOrigin = href is String && _origin(href) == job.request.origin;
      if (ready && sameOrigin && !challenge) {
        session.verifiedAt[job.request.origin] = _clock();
        return job.hadChallenge ? 'verified' : 'not-required';
      }
      if (challenge) {
        job.hadChallenge = true;
        final elapsed = Duration(
          milliseconds:
              job.request.timeoutMs -
              (job.deadlineUnixMs - _clock().millisecondsSinceEpoch),
        );
        if (elapsed >= _interactionGrace &&
            (job.request.interaction == 'silent' ||
                job.request.presentation == 'hidden')) {
          throw const WindowsBrowserSessionException('interaction_required');
        }
      }
      await Future<void>.delayed(_pollDelay);
    }
  }

  Future<String?> _currentOrigin(_WindowsBrowserSession session) async {
    final raw = await _platform.executeScript(
      session.sessionId,
      'location.origin',
    );
    final value = jsonDecode(raw);
    return value is String ? value : null;
  }

  Future<Map<String, Object?>> _webViewFetch(
    _WindowsBrowserJob job,
    _WindowsBrowserSession session,
    String verificationState,
  ) async {
    await _platform.executeScript(session.sessionId, _fetchScript(job));
    final key = jsonEncode(job.id);
    while (true) {
      _check(job);
      final raw = await _platform.executeScript(
        session.sessionId,
        "(() => { const r=globalThis.__mgreadFetchResults?.[$key];if(r===undefined)return null;delete globalThis.__mgreadFetchResults[$key];return r; })()",
      );
      final encoded = jsonDecode(raw);
      if (encoded is String) {
        final result = jsonDecode(encoded);
        if (result is! Map<Object?, Object?> || result['ok'] != true) {
          final code =
              result is Map<Object?, Object?> && result['code'] is String
              ? result['code']! as String
              : 'plugin_execution_failed';
          throw WindowsBrowserSessionException(code);
        }
        final response = _stringMap(result['response']);
        return <String, Object?>{
          ...response,
          'version': 1,
          'verificationState': _looksLikeChallenge(response['body'])
              ? 'failed'
              : verificationState,
        };
      }
      await Future<void>.delayed(_pollDelay);
    }
  }

  Future<Map<String, Object?>> _httpFetch(
    _WindowsBrowserJob job,
    _WindowsBrowserSession session,
    String verificationState, {
    bool retried = false,
  }) async {
    final request = job.request;
    final cookieValues = await _platform.getCookies(
      session.sessionId,
      request.url,
    );
    final cookie = cookieValues
        .where((value) => value['name'] is String && value['value'] is String)
        .map((value) => '${value['name']}=${value['value']}')
        .join('; ');
    final userAgentRaw = await _platform.executeScript(
      session.sessionId,
      'navigator.userAgent',
    );
    final decodedUserAgent = jsonDecode(userAgentRaw);
    if (decodedUserAgent is! String || decodedUserAgent.isEmpty) {
      throw const WindowsBrowserSessionException('plugin_execution_failed');
    }
    var url = Uri.parse(request.url);
    var method = request.method;
    var body = request.body;
    final client = _httpClientFactory()
      ..connectionTimeout = Duration(milliseconds: _remaining(job))
      ..autoUncompress = true;
    job.client = client;
    for (var redirect = 0; redirect <= 5; redirect += 1) {
      _check(job);
      final outbound = await client
          .openUrl(method, url)
          .timeout(Duration(milliseconds: _remaining(job)));
      outbound.followRedirects = false;
      outbound.headers.set(HttpHeaders.userAgentHeader, decodedUserAgent);
      if (cookie.isNotEmpty)
        outbound.headers.set(HttpHeaders.cookieHeader, cookie);
      for (final entry in request.headers.entries) {
        outbound.headers.set(entry.key, entry.value);
      }
      if (method == 'POST') outbound.write(body ?? '');
      final response = await outbound.close().timeout(
        Duration(milliseconds: _remaining(job)),
      );
      for (final value
          in response.headers[HttpHeaders.setCookieHeader] ??
              const <String>[]) {
        await _storeCookie(session, url, value);
      }
      if (<int>{301, 302, 303, 307, 308}.contains(response.statusCode) &&
          redirect < 5) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null) {
          return _finishHttpResponse(
            job,
            session,
            response,
            url,
            verificationState,
            retried,
          );
        }
        final next = url.resolve(location);
        if (_origin(next.toString()) != request.origin) {
          throw const WindowsBrowserSessionException('plugin_execution_failed');
        }
        url = next;
        if (response.statusCode == 303 ||
            ((response.statusCode == 301 || response.statusCode == 302) &&
                method == 'POST')) {
          method = 'GET';
          body = null;
        }
        await response.drain<void>();
        continue;
      }
      return _finishHttpResponse(
        job,
        session,
        response,
        url,
        verificationState,
        retried,
      );
    }
    throw const WindowsBrowserSessionException('plugin_execution_failed');
  }

  Future<Map<String, Object?>> _finishHttpResponse(
    _WindowsBrowserJob job,
    _WindowsBrowserSession session,
    HttpClientResponse response,
    Uri finalUrl,
    String verificationState,
    bool retried,
  ) async {
    final result = await _httpResponse(
      job,
      response,
      finalUrl,
      verificationState,
    );
    if (result['verificationState'] == 'failed' && !retried) {
      job.client?.close(force: true);
      job.client = null;
      session.verifiedAt.remove(job.request.origin);
      final refreshed = await _verify(job, session);
      return _httpFetch(job, session, refreshed, retried: true);
    }
    return result;
  }

  Future<Map<String, Object?>> _httpResponse(
    _WindowsBrowserJob job,
    HttpClientResponse response,
    Uri finalUrl,
    String verificationState,
  ) async {
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > job.request.maxResponseBytes) {
        throw const WindowsBrowserSessionException('overloaded');
      }
      _check(job);
    }
    final contentType = response.headers.contentType;
    final body = contentType?.charset?.toLowerCase() == 'iso-8859-1'
        ? latin1.decode(bytes)
        : utf8.decode(bytes, allowMalformed: true);
    final headers = <String, String>{};
    for (final name in const <String>[
      'cache-control',
      'content-type',
      'etag',
      'expires',
      'last-modified',
    ]) {
      final value = response.headers.value(name);
      if (value != null && value.length <= 1024) headers[name] = value;
    }
    return <String, Object?>{
      'version': 1,
      'status': response.statusCode,
      'finalUrl': finalUrl.toString(),
      'headers': headers,
      'body': body,
      'verificationState': _looksLikeChallenge(body)
          ? 'failed'
          : verificationState,
    };
  }

  Future<void> _storeCookie(
    _WindowsBrowserSession session,
    Uri url,
    String raw,
  ) async {
    try {
      final cookie = Cookie.fromSetCookieValue(raw);
      await _platform.setCookie(session.sessionId, <String, Object?>{
        'name': cookie.name,
        'value': cookie.value,
        'domain': cookie.domain ?? url.host,
        'path': cookie.path ?? '/',
        'expires': cookie.expires?.millisecondsSinceEpoch,
        'httpOnly': cookie.httpOnly,
        'secure': cookie.secure,
      });
    } on Object {
      // An invalid Set-Cookie must not expose credentials or invalidate a valid response.
    }
  }

  void _check(_WindowsBrowserJob job) {
    if (job.cancelled) throw const WindowsBrowserSessionException('cancelled');
    if (_remaining(job) <= 0)
      throw const WindowsBrowserSessionException('timeout');
  }

  int _remaining(_WindowsBrowserJob job) =>
      job.deadlineUnixMs - _clock().millisecondsSinceEpoch;
}

final class _WindowsBrowserRequest {
  const _WindowsBrowserRequest({
    required this.body,
    required this.headers,
    required this.interaction,
    required this.maxResponseBytes,
    required this.method,
    required this.pluginId,
    required this.presentation,
    required this.sessionKey,
    required this.timeoutMs,
    required this.transport,
    required this.url,
    required this.origin,
  });

  final String? body;
  final Map<String, String> headers;
  final String interaction;
  final int maxResponseBytes;
  final String method;
  final String pluginId;
  final String presentation;
  final String sessionKey;
  final int timeoutMs;
  final String transport;
  final String url;
  final String origin;

  static _WindowsBrowserRequest parse(Map<String, Object?> value) {
    if (utf8.encode(jsonEncode(value)).length > _maximumRequestBytes ||
        value['version'] != 1)
      _invalid();
    final pluginId = _required(value, 'pluginId', 160);
    final sessionKey = _required(value, 'sessionKey', 64);
    if (!RegExp(r'^[a-z0-9]+(?:[._-][a-z0-9]+)+$').hasMatch(pluginId) ||
        !RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(sessionKey))
      _invalid();
    final url = _required(value, 'url', 4096);
    final origin = _origin(url);
    final method = _required(value, 'method', 4);
    final interaction = _required(value, 'interaction', 8);
    final presentation = _required(value, 'presentation', 7);
    final transport = _required(value, 'transport', 7);
    final timeoutMs = value['timeoutMs'];
    final maxResponseBytes = value['maxResponseBytes'];
    final body = value['body'];
    if (!const <String>{'GET', 'POST'}.contains(method) ||
        !const <String>{'allow', 'silent'}.contains(interaction) ||
        !const <String>{'hidden', 'visible'}.contains(presentation) ||
        !const <String>{'http', 'webview'}.contains(transport) ||
        timeoutMs is! int ||
        timeoutMs < 1000 ||
        timeoutMs > _maximumTimeoutMs ||
        maxResponseBytes is! int ||
        maxResponseBytes < 1 ||
        maxResponseBytes > _maximumResponseBytes ||
        (body != null && body is! String) ||
        (method == 'GET' && body != null))
      _invalid();
    final headers = _headers(value['headers'], origin);
    return _WindowsBrowserRequest(
      body: body as String?,
      headers: headers,
      interaction: interaction,
      maxResponseBytes: maxResponseBytes,
      method: method,
      pluginId: pluginId,
      presentation: presentation,
      sessionKey: sessionKey,
      timeoutMs: timeoutMs,
      transport: transport,
      url: url,
      origin: origin,
    );
  }

  static Map<String, String> _headers(Object? raw, String origin) {
    if (raw is! Map<Object?, Object?> || raw.length > 16) _invalid();
    final result = <String, String>{};
    for (final entry in raw.entries) {
      final name = entry.key is String
          ? (entry.key! as String).toLowerCase()
          : '';
      final value = entry.value;
      if (!const <String>{
            'accept',
            'accept-language',
            'content-type',
            'origin',
            'referer',
          }.contains(name) ||
          value is! String ||
          value.length > 1024)
        _invalid();
      if ((name == 'origin' || name == 'referer') &&
          _origin(Uri.parse(origin).resolve(value).toString()) != origin)
        _invalid();
      result[name] = value;
    }
    return result;
  }
}

final class _WindowsBrowserSession {
  _WindowsBrowserSession(this.pluginId, this.sessionId, this.lastUsedAt);

  final String pluginId;
  final String sessionId;
  final Map<String, DateTime> verifiedAt = <String, DateTime>{};
  String? activeJobId;
  DateTime lastUsedAt;
}

final class _WindowsBrowserJob {
  _WindowsBrowserJob(this.id, this.deadlineUnixMs, this.request);

  final String id;
  final int deadlineUnixMs;
  final _WindowsBrowserRequest request;
  bool cancelled = false;
  bool hadChallenge = false;
  HttpClient? client;
}

Map<String, Object?>? _decodeScriptObject(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! String) return null;
  final value = jsonDecode(decoded);
  return value is Map<Object?, Object?> ? _stringMap(value) : null;
}

Map<String, Object?> _stringMap(Object? value) {
  if (value is! Map<Object?, Object?>)
    throw const WindowsBrowserSessionException('plugin_execution_failed');
  return <String, Object?>{
    for (final entry in value.entries)
      if (entry.key is String) entry.key! as String: entry.value,
  };
}

String _required(Map<String, Object?> value, String key, int maximumLength) {
  final field = value[key];
  if (field is! String || field.isEmpty || field.length > maximumLength)
    _invalid();
  return field;
}

Never _invalid() =>
    throw const WindowsBrowserSessionException('plugin_execution_failed');

String _origin(String value) {
  final uri = Uri.parse(value);
  if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty)
    _invalid();
  return Uri(
    scheme: 'https',
    host: uri.host.toLowerCase(),
    port: uri.hasPort && uri.port != 443 ? uri.port : null,
  ).origin;
}

bool _looksLikeChallenge(Object? value) =>
    value is String &&
    RegExp(
      r'cf-challenge|cf-turnstile|just a moment|checking your browser|challenge-platform',
      caseSensitive: false,
    ).hasMatch(value);

String _fetchScript(_WindowsBrowserJob job) {
  final request = job.request;
  final key = jsonEncode(job.id);
  final url = jsonEncode(request.url);
  final method = jsonEncode(request.method);
  final headers = jsonEncode(jsonEncode(request.headers));
  final body = request.body == null ? 'null' : jsonEncode(request.body);
  final origin = jsonEncode(request.origin);
  return """(() => {globalThis.__mgreadFetchResults ??= Object.create(null);const key=$key;(async()=>{try{const response=await fetch($url,{method:$method,headers:JSON.parse($headers),body:$body,credentials:'include',redirect:'follow'});const body=await response.text();if(new TextEncoder().encode(body).byteLength>${request.maxResponseBytes}){globalThis.__mgreadFetchResults[key]=JSON.stringify({ok:false,code:'overloaded'});return;}const finalUrl=new URL(response.url);if(finalUrl.origin!==$origin)throw new Error('cross_origin');const headers={};for(const name of ['cache-control','content-type','etag','expires','last-modified']){const value=response.headers.get(name);if(value!==null)headers[name]=value.slice(0,1024);}globalThis.__mgreadFetchResults[key]=JSON.stringify({ok:true,response:{status:response.status,finalUrl:response.url,headers,body}});}catch(_){globalThis.__mgreadFetchResults[key]=JSON.stringify({ok:false,code:'plugin_execution_failed'});}})();return 'started';})()""";
}

const _pageProbeScript =
    """(() => {try{const text=(document.title+' '+(document.documentElement?.innerText||'')).slice(0,200000);return JSON.stringify({href:location.href,ready:document.readyState==='complete',challenge:/(cf-challenge|cf-turnstile|just a moment|checking your browser|challenge-platform)/i.test(text)});}catch(_){return null;}})()""";
