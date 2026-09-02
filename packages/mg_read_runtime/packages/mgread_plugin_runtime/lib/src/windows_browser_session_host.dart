/// Windows owner for browser.session.v1 and the single-page ctx.webview boundary.
///
/// One plugin owns at most one WebView2 and isolated user-data folder. Fixed
/// host scripts implement browser fetch; direct HTTP temporarily reads the
/// profile Cookie/UA and writes Set-Cookie updates back without exposing them.
/// The new page API carries explicitly requested script bodies, raw CDP
/// commands, and JSON results; all supporting scripts and native inputs remain
/// host-owned.
/// Closing the native verification window invalidates that session; the next
/// visible source request recreates it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/services.dart';

part 'windows_webview_page.dart';

const _maximumRequestBytes = 1024 * 1024;
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

/// Narrow native WebView2 surface. CDP commands are passed through only after
/// Runtime JSON validation.
abstract interface class WindowsBrowserPlatform {
  Future<String> create({
    required String pluginId,
    required String pluginName,
    required String profilePath,
  });
  Future<void> dispose(String sessionId);
  Future<void> dispatchMouseInput(
    String sessionId, {
    required double x,
    required double y,
    required double devicePixelRatio,
  });
  Future<String> callDevToolsProtocolMethod(
    String sessionId, {
    required String method,
    required String paramsJson,
  });
  Future<String> executeScript(String sessionId, String script);
  Future<void> insertText(String sessionId, String text);
  Future<void> dispatchKey(
    String sessionId, {
    required String key,
    required List<String> modifiers,
  });
  Future<List<Map<String, Object?>>> getCookies(String sessionId, String url);
  Future<void> hide(String sessionId);
  Future<void> load(String sessionId, String url);
  Future<void> setCookie(String sessionId, Map<String, Object?> cookie);
  Future<void> show(String sessionId);
  Future<void> stop(String sessionId);
  Future<void> updateStatus(String sessionId, String status);
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
    required String pluginName,
    required String profilePath,
  }) async {
    final value = await _channel.invokeMethod<String>(
      'create',
      <String, Object?>{
        'pluginId': pluginId,
        'pluginName': pluginName,
        'profilePath': profilePath,
      },
    );
    if (value == null || value.isEmpty)
      throw const WindowsBrowserSessionException('unsupported');
    return value;
  }

  @override
  Future<void> dispose(String sessionId) => _invoke('dispose', sessionId);

  @override
  Future<void> dispatchMouseInput(
    String sessionId, {
    required double x,
    required double y,
    required double devicePixelRatio,
  }) => _channel.invokeMethod<void>('dispatchMouseInput', <String, Object?>{
    'sessionId': sessionId,
    'x': x,
    'y': y,
    'devicePixelRatio': devicePixelRatio,
  });

  @override
  Future<void> insertText(String sessionId, String text) =>
      _channel.invokeMethod<void>('insertText', <String, Object?>{
        'sessionId': sessionId,
        'text': text,
      });

  @override
  Future<void> dispatchKey(
    String sessionId, {
    required String key,
    required List<String> modifiers,
  }) => _channel.invokeMethod<void>('dispatchKey', <String, Object?>{
    'sessionId': sessionId,
    'key': key,
    'modifiers': modifiers,
  });

  @override
  Future<String> callDevToolsProtocolMethod(
    String sessionId, {
    required String method,
    required String paramsJson,
  }) async {
    final value = await _channel.invokeMethod<String>(
      'callDevToolsProtocolMethod',
      <String, Object?>{
        'sessionId': sessionId,
        'method': method,
        'paramsJson': paramsJson,
      },
    );
    if (value == null)
      throw const WindowsBrowserSessionException('plugin_execution_failed');
    return value;
  }

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

  @override
  Future<void> updateStatus(String sessionId, String status) =>
      _channel.invokeMethod<void>('updateStatus', <String, Object?>{
        'sessionId': sessionId,
        'status': status,
      });

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
  final Set<String> _debugPinnedPlugins = <String>{};
  Completer<void>? _sessionCreationGate;
  bool _disposed = false;

  Future<Map<String, Object?>> request({
    required String jobId,
    required int deadlineUnixMs,
    required Map<String, Object?> raw,
  }) async {
    if (_disposed) throw const WindowsBrowserSessionException('unsupported');
    if (raw['operation'] == 'debug') {
      return _requestDebug(deadlineUnixMs: deadlineUnixMs, raw: raw);
    }
    if (raw['operation'] is String &&
        (raw['operation']! as String).startsWith('page.')) {
      return _requestPage(
        jobId: jobId,
        deadlineUnixMs: deadlineUnixMs,
        raw: raw,
      );
    }
    final request = _WindowsBrowserRequest.parse(raw);
    _log(
      'browser_session_start plugin_id=${request.pluginId} '
      'transport=${request.transport} presentation=${request.presentation}',
    );
    if (_jobs.length >= _maximumPendingRequests)
      throw const WindowsBrowserSessionException('overloaded');
    final job = _WindowsBrowserJob(jobId, deadlineUnixMs, request);
    _jobs[jobId] = job;
    _WindowsBrowserSession? session;
    try {
      session = await _sessionFor(request.pluginId, request.pluginId);
      if (session.activeJobId != null)
        throw const WindowsBrowserSessionException('overloaded');
      session.activeJobId = jobId;
      session.lastUsedAt = _clock();
      if (request.presentation == 'visible') {
        try {
          await _platform.show(session.sessionId);
          _log(
            'browser_session_verification_window_shown '
            'plugin_id=${request.pluginId}',
          );
        } on PlatformException catch (error) {
          if (error.code != 'unsupported') rethrow;
          if (identical(_sessions[request.pluginId], session)) {
            _sessions.remove(request.pluginId);
          }
          session.activeJobId = null;
          session = await _sessionFor(request.pluginId, request.pluginId);
          if (session.activeJobId != null)
            throw const WindowsBrowserSessionException('overloaded');
          session.activeJobId = jobId;
          session.lastUsedAt = _clock();
          await _platform.show(session.sessionId);
          _log(
            'browser_session_verification_window_shown '
            'plugin_id=${request.pluginId} recreated=true',
          );
        }
      }
      final cachedAt = session.verifiedAt[request.origin];
      final cached =
          cachedAt != null &&
          _clock().difference(cachedAt) <= _verificationCache;
      final sameOrigin =
          cached && await _currentOrigin(session) == request.origin;
      final state = sameOrigin ? 'verified' : await _verify(job, session);
      if (request.operation == 'interaction') {
        return await _interact(job, session);
      }
      if (request.transport == 'webview') {
        return await _webViewFetch(job, session, state);
      }
      if (request.transport == 'html') {
        return await _pageHtml(job, session, state);
      }
      return await _httpFetch(job, session, state);
    } on WindowsBrowserSessionException catch (error) {
      _log(
        'browser_session_terminal plugin_id=${request.pluginId} '
        'code=${error.code}',
      );
      rethrow;
    } on MissingPluginException {
      _log(
        'browser_session_terminal plugin_id=${request.pluginId} '
        'code=unsupported',
      );
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
      final code = allowed.contains(error.code)
          ? error.code
          : 'plugin_execution_failed';
      _log(
        'browser_session_terminal plugin_id=${request.pluginId} '
        'code=$code',
      );
      throw WindowsBrowserSessionException(code);
    } on TimeoutException {
      _log(
        'browser_session_terminal plugin_id=${request.pluginId} '
        'code=timeout',
      );
      throw const WindowsBrowserSessionException('timeout');
    } on Object {
      final code = job.cancelled ? 'cancelled' : 'plugin_execution_failed';
      _log(
        'browser_session_terminal plugin_id=${request.pluginId} '
        'code=$code',
      );
      if (job.cancelled)
        throw const WindowsBrowserSessionException('cancelled');
      throw const WindowsBrowserSessionException('plugin_execution_failed');
    } finally {
      _jobs.remove(jobId);
      job.client?.close(force: true);
      if (session?.activeJobId == jobId) session!.activeJobId = null;
    }
  }

  Future<Map<String, Object?>> _requestDebug({
    required int deadlineUnixMs,
    required Map<String, Object?> raw,
  }) async {
    final pluginId = raw['pluginId'];
    final pluginName = raw['pluginName'];
    final action = raw['action'];
    final timeoutMs = raw['timeoutMs'];
    if (pluginId is! String ||
        !RegExp(r'^[a-z0-9]+(?:[._-][a-z0-9]+)+$').hasMatch(pluginId) ||
        pluginName is! String ||
        pluginName.isEmpty ||
        pluginName.length > 128 ||
        (action != 'enter' && action != 'show') ||
        timeoutMs is! int ||
        timeoutMs < 1 ||
        timeoutMs > _maximumTimeoutMs) {
      throw const WindowsBrowserSessionException('plugin_execution_failed');
    }
    if (deadlineUnixMs <= _clock().millisecondsSinceEpoch) {
      throw const WindowsBrowserSessionException('timeout');
    }
    _debugPinnedPlugins.add(pluginId);
    var session = await _sessionFor(pluginId, pluginName);
    try {
      await _platform.updateStatus(
        session.sessionId,
        '$pluginName正在进行探测 - ${action == 'enter' ? 'WebView 调试' : '已显示'}',
      );
      await _platform.show(session.sessionId);
    } on PlatformException catch (error) {
      if (error.code != 'unsupported') rethrow;
      if (identical(_sessions[pluginId], session)) _sessions.remove(pluginId);
      session = await _sessionFor(pluginId, pluginName);
      await _platform.show(session.sessionId);
    }
    session.visible = true;
    _log(
      'browser_session_debug_window_shown plugin_id=$pluginId action=$action',
    );
    return <String, Object?>{'accepted': true, 'action': action, 'version': 1};
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

  Future<_WindowsBrowserSession> _sessionFor(
    String pluginId,
    String pluginName,
  ) async {
    final existing = _sessions[pluginId];
    if (existing != null) {
      _log('browser_session_reuse plugin_id=$pluginId');
      return existing;
    }
    final pending = _creating[pluginId];
    if (pending != null) return pending;
    final created = _createSessionSerially(pluginId, pluginName);
    _creating[pluginId] = created;
    try {
      return await created;
    } finally {
      _creating.remove(pluginId);
    }
  }

  Future<_WindowsBrowserSession> _createSessionSerially(
    String pluginId,
    String pluginName,
  ) async {
    while (true) {
      final pending = _sessionCreationGate;
      if (pending == null) break;
      await pending.future;
    }
    final gate = Completer<void>();
    _sessionCreationGate = gate;
    try {
      return await _createSession(pluginId, pluginName);
    } finally {
      if (identical(_sessionCreationGate, gate)) _sessionCreationGate = null;
      gate.complete();
    }
  }

  Future<_WindowsBrowserSession> _createSession(
    String pluginId,
    String pluginName,
  ) async {
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
      pluginName: pluginName,
      profilePath: profile.path,
    );
    final session = _WindowsBrowserSession(
      pluginId,
      pluginName,
      sessionId,
      _clock(),
    );
    _sessions[pluginId] = session;
    _log('browser_session_created plugin_id=$pluginId');
    return session;
  }

  Future<String> _verify(
    _WindowsBrowserJob job,
    _WindowsBrowserSession session,
  ) async {
    _log(
      'browser_session_verification_start plugin_id=${job.request.pluginId}',
    );
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
        _log(
          'browser_session_manual_verification_success '
          'plugin_id=${job.request.pluginId} had_challenge=${job.hadChallenge}',
        );
        return job.hadChallenge ? 'verified' : 'not-required';
      }
      if (challenge) {
        job.hadChallenge = true;
        _log('browser_session_cf_detected plugin_id=${job.request.pluginId}');
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
    _log('browser_session_fetch_start plugin_id=${job.request.pluginId}');
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
        if (_isChallengeResponse(response)) {
          job.hadChallenge = true;
          session.verifiedAt.remove(job.request.origin);
          _log(
            'browser_session_cf_detected plugin_id=${job.request.pluginId} phase=fetch',
          );
          if (job.retries > 0 ||
              job.request.interaction == 'silent' ||
              job.request.presentation == 'hidden') {
            _log(
              'browser_session_interaction_required '
              'plugin_id=${job.request.pluginId} phase=fetch',
            );
            throw const WindowsBrowserSessionException('interaction_required');
          }
          job.retries += 1;
          _log(
            'browser_session_retry plugin_id=${job.request.pluginId} phase=fetch',
          );
          final refreshed = await _verify(job, session);
          return _webViewFetch(job, session, refreshed);
        }
        _log(
          'browser_session_fetch_complete plugin_id=${job.request.pluginId} '
          'status=${response['status']}',
        );
        return <String, Object?>{
          ...response,
          'version': 1,
          'verificationState': verificationState,
        };
      }
      await Future<void>.delayed(_pollDelay);
    }
  }

  Future<Map<String, Object?>> _interact(
    _WindowsBrowserJob job,
    _WindowsBrowserSession session,
  ) async {
    _check(job);
    final raw = await _platform.executeScript(
      session.sessionId,
      _interactionTargetScript(job.request),
    );
    _check(job);
    final result = _decodeScriptObject(raw);
    if (result == null ||
        result['accepted'] != true ||
        result['action'] != job.request.action) {
      throw const WindowsBrowserSessionException('plugin_execution_failed');
    }
    if (job.request.action == 'coordinates') {
      return <String, Object?>{...result, 'version': 1};
    }
    final x = _finiteNumber(result['x']);
    final y = _finiteNumber(result['y']);
    final devicePixelRatio = _finiteNumber(result['devicePixelRatio']);
    if (x == null ||
        y == null ||
        devicePixelRatio == null ||
        devicePixelRatio <= 0) {
      throw const WindowsBrowserSessionException('plugin_execution_failed');
    }
    await _platform.dispatchMouseInput(
      session.sessionId,
      x: x,
      y: y,
      devicePixelRatio: devicePixelRatio,
    );
    _check(job);
    if (job.request.action == 'native-input') {
      await _platform.insertText(session.sessionId, job.request.text!);
      _check(job);
    }
    return <String, Object?>{
      'accepted': true,
      'action': job.request.action,
      'version': 1,
    };
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

  Future<Map<String, Object?>> _pageHtml(
    _WindowsBrowserJob job,
    _WindowsBrowserSession session,
    String verificationState,
  ) async {
    _log(
      'browser_session_fetch_start plugin_id=${job.request.pluginId} phase=html',
    );
    final value = _decodeScriptObject(
      await _platform.executeScript(session.sessionId, _pageHtmlScript(job)),
    );
    if (value == null || value['ok'] != true) {
      final code = value?['code'];
      throw WindowsBrowserSessionException(
        code is String ? code : 'plugin_execution_failed',
      );
    }
    final response = _stringMap(value['response']);
    if (_isChallengeResponse(response)) {
      job.hadChallenge = true;
      session.verifiedAt.remove(job.request.origin);
      _log(
        'browser_session_cf_detected plugin_id=${job.request.pluginId} phase=html',
      );
      if (job.retries > 0 ||
          job.request.interaction == 'silent' ||
          job.request.presentation == 'hidden') {
        _log(
          'browser_session_interaction_required '
          'plugin_id=${job.request.pluginId} phase=html',
        );
        throw const WindowsBrowserSessionException('interaction_required');
      }
      job.retries += 1;
      _log(
        'browser_session_retry plugin_id=${job.request.pluginId} phase=html',
      );
      final refreshed = await _verify(job, session);
      return _pageHtml(job, session, refreshed);
    }
    _log(
      'browser_session_fetch_complete plugin_id=${job.request.pluginId} phase=html',
    );
    return <String, Object?>{
      ...response,
      'version': 1,
      'verificationState': verificationState,
    };
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
    if (result['verificationState'] == 'failed') {
      _log(
        'browser_session_interaction_required plugin_id=${job.request.pluginId} phase=http',
      );
      throw const WindowsBrowserSessionException('interaction_required');
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
      // An invalid Set-Cookie does not invalidate an otherwise valid response.
    }
  }

  void _check(_WindowsBrowserJob job) {
    if (job.cancelled) throw const WindowsBrowserSessionException('cancelled');
    if (_remaining(job) <= 0)
      throw const WindowsBrowserSessionException('timeout');
  }

  int _remaining(_WindowsBrowserJob job) =>
      job.deadlineUnixMs - _clock().millisecondsSinceEpoch;

  void _log(String message) =>
      developer.log(message, name: 'MgReadWindowsBrowser');
}

final class _WindowsBrowserRequest {
  const _WindowsBrowserRequest({
    required this.action,
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
    required this.operation,
    required this.selector,
    required this.text,
  });

  final String action;
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
  final String operation;
  final String selector;
  final String? text;

  factory _WindowsBrowserRequest.pagePlaceholder(_WindowsPageRequest request) =>
      _WindowsBrowserRequest(
        action: '',
        body: null,
        headers: const <String, String>{},
        interaction: 'silent',
        maxResponseBytes: _maximumResponseBytes,
        method: 'GET',
        pluginId: request.pluginId,
        presentation: 'hidden',
        sessionKey: '',
        timeoutMs: request.timeoutMs,
        transport: 'webview',
        url: request.url ?? 'https://invalid.example/',
        origin: 'https://invalid.example',
        operation: request.operation,
        selector: '',
        text: request.text,
      );

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
    final operation = value['operation'] is String
        ? value['operation']! as String
        : 'request';
    if (operation == 'interaction') {
      final action = _required(value, 'action', 16);
      final presentation = _required(value, 'presentation', 7);
      final timeoutMs = value['timeoutMs'];
      final selector = _required(value, 'selector', 512);
      final text = value['text'];
      if (!const <String>{
            'coordinates',
            'native-input',
            'control-click',
          }.contains(action) ||
          !const <String>{'hidden', 'visible'}.contains(presentation) ||
          timeoutMs is! int ||
          timeoutMs < 1000 ||
          timeoutMs > _maximumTimeoutMs ||
          (action == 'native-input' &&
              (text is! String || text.length > 16 * 1024)) ||
          (action != 'native-input' && text != null))
        _invalid();
      return _WindowsBrowserRequest(
        action: action,
        body: null,
        headers: <String, String>{},
        interaction: 'allow',
        maxResponseBytes: 1,
        method: 'GET',
        operation: operation,
        pluginId: pluginId,
        presentation: presentation,
        selector: selector,
        sessionKey: sessionKey,
        text: text as String?,
        timeoutMs: timeoutMs,
        transport: 'webview',
        url: url,
        origin: origin,
      );
    }
    if (operation != 'request') _invalid();
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
        !const <String>{'html', 'http', 'webview'}.contains(transport) ||
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
      action: '',
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
      operation: operation,
      selector: '',
      text: null,
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
  _WindowsBrowserSession(
    this.pluginId,
    this.pluginName,
    this.sessionId,
    this.lastUsedAt,
  );

  final String pluginId;
  final String pluginName;
  final String sessionId;
  final Map<String, DateTime> verifiedAt = <String, DateTime>{};
  String? activeJobId;
  DateTime lastUsedAt;
  bool visible = false;
}

final class _WindowsBrowserJob {
  _WindowsBrowserJob(this.id, this.deadlineUnixMs, this.request);

  final String id;
  final int deadlineUnixMs;
  final _WindowsBrowserRequest request;
  bool cancelled = false;
  bool hadChallenge = false;
  int retries = 0;
  HttpClient? client;
}
