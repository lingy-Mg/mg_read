part of 'windows_browser_session_host.dart';

/// Single-page ctx.webview state machine kept separate from legacy v1 HTTP flow.
/// Async page jobs use revocable realm tokens so late promises cannot leak results.
extension on WindowsBrowserSessionHost {
  Future<Map<String, Object?>> _requestPage({
    required String jobId,
    required int deadlineUnixMs,
    required Map<String, Object?> raw,
  }) async {
    final request = _WindowsPageRequest.parse(raw);
    if (_jobs.length >= _maximumPendingRequests) {
      throw const WindowsBrowserSessionException('overloaded');
    }
    if (request.operation == 'page.close') {
      final session = _sessions.remove(request.pluginId);
      if (session != null) await _platform.dispose(session.sessionId);
      return <String, Object?>{};
    }
    if (request.operation == 'page.show' || request.operation == 'page.hide') {
      final session = _sessions[request.pluginId];
      if (session == null)
        throw const WindowsBrowserSessionException('unsupported');
      if (request.operation == 'page.show') {
        await _platform.updateStatus(
          session.sessionId,
          '${request.pluginName}正在进行探测 - 已显示',
        );
        await _platform.show(session.sessionId);
        session.visible = true;
      } else {
        if (_debugPinnedPlugins.contains(request.pluginId)) {
          session.visible = true;
          return <String, Object?>{};
        }
        await _platform.hide(session.sessionId);
        session.visible = false;
      }
      return <String, Object?>{};
    }
    var session = await _sessionFor(request.pluginId, request.pluginName);
    if (request.operation == 'page.open') {
      if (request.visible || _debugPinnedPlugins.contains(request.pluginId)) {
        await _platform.updateStatus(
          session.sessionId,
          '${request.pluginName}正在进行探测 - 已打开',
        );
        await _platform.show(session.sessionId);
        session.visible = true;
      }
      return <String, Object?>{};
    }
    if (session.activeJobId != null) {
      throw const WindowsBrowserSessionException('overloaded');
    }
    final legacyRequest = _WindowsBrowserRequest.pagePlaceholder(request);
    final job = _WindowsBrowserJob(jobId, deadlineUnixMs, legacyRequest);
    _jobs[jobId] = job;
    session.activeJobId = jobId;
    session.lastUsedAt = _clock();
    try {
      await _platform.updateStatus(
        session.sessionId,
        '${request.pluginName}正在进行探测 - ${_pageOperationLabel(request.operation)}',
      );
      switch (request.operation) {
        case 'page.navigate':
          await _platform.load(session.sessionId, request.url!);
          while (true) {
            _check(job);
            final state = jsonDecode(
              await _platform.executeScript(
                session.sessionId,
                'document.readyState',
              ),
            );
            if (state == 'interactive' || state == 'complete')
              return <String, Object?>{};
            await Future<void>.delayed(_pollDelay);
          }
        case 'page.evaluate':
          return await _runPageScript(
            job,
            session,
            "const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;"
            "const value=await new AsyncFunction(${jsonEncode(request.code)}).call(window);return {value};",
          );
        case 'page.cdp':
          final raw = await _platform.callDevToolsProtocolMethod(
            session.sessionId,
            method: request.cdpMethod!,
            paramsJson: jsonEncode(request.cdpParams),
          );
          try {
            return <String, Object?>{'value': jsonDecode(raw)};
          } on FormatException {
            throw const WindowsBrowserSessionException(
              'plugin_execution_failed',
            );
          }
        case 'page.html':
          final result = _decodeScriptObject(
            await _platform.executeScript(
              session.sessionId,
              "JSON.stringify({html:document.documentElement?.outerHTML??''})",
            ),
          );
          if (result == null || result['html'] is! String) {
            throw const WindowsBrowserSessionException(
              'plugin_execution_failed',
            );
          }
          return result;
        case 'page.fetch':
          return await _runPageScript(job, session, _pageFetchBody(request));
        case 'page.click':
          if (!session.visible)
            throw const WindowsBrowserSessionException('interaction_required');
          final ratio = jsonDecode(
            await _platform.executeScript(
              session.sessionId,
              'window.devicePixelRatio||1',
            ),
          );
          if (ratio is! num || !ratio.isFinite || ratio <= 0) {
            throw const WindowsBrowserSessionException(
              'plugin_execution_failed',
            );
          }
          await _platform.dispatchMouseInput(
            session.sessionId,
            x: request.x!,
            y: request.y!,
            devicePixelRatio: ratio.toDouble(),
          );
          return <String, Object?>{};
        case 'page.input':
          if (!session.visible)
            throw const WindowsBrowserSessionException('interaction_required');
          await _platform.insertText(session.sessionId, request.text!);
          return <String, Object?>{};
        case 'page.key':
          if (!session.visible)
            throw const WindowsBrowserSessionException('interaction_required');
          await _platform.dispatchKey(
            session.sessionId,
            key: request.key!,
            modifiers: request.modifiers,
          );
          return <String, Object?>{};
        case 'page.waitText':
          final expression = request.scope == 'html'
              ? "document.documentElement?.outerHTML??''"
              : "document.documentElement?.innerText??''";
          while (true) {
            _check(job);
            final matched = jsonDecode(
              await _platform.executeScript(
                session.sessionId,
                "(() => ($expression).includes(${jsonEncode(request.text)}))()",
              ),
            );
            if (matched == true) {
              final url = jsonDecode(
                await _platform.executeScript(
                  session.sessionId,
                  'location.href',
                ),
              );
              return <String, Object?>{'url': url is String ? url : ''};
            }
            await Future<void>.delayed(_pollDelay);
          }
        case 'page.getUrl':
          final url = jsonDecode(
            await _platform.executeScript(session.sessionId, 'location.href'),
          );
          return <String, Object?>{'url': url is String ? url : ''};
      }
      throw const WindowsBrowserSessionException('unsupported');
    } on TimeoutException {
      throw const WindowsBrowserSessionException('timeout');
    } finally {
      if (_pageAsyncOperations.contains(request.operation)) {
        await _expirePageScriptResult(session, jobId);
      }
      _jobs.remove(jobId);
      if (session.activeJobId == jobId) session.activeJobId = null;
    }
  }

  Future<Map<String, Object?>> _runPageScript(
    _WindowsBrowserJob job,
    _WindowsBrowserSession session,
    String body,
  ) async {
    final key = jsonEncode(job.id);
    await _platform.executeScript(
      session.sessionId,
      """(() => {globalThis.__mgreadPageResults??=Object.create(null);globalThis.__mgreadPageJobs??=Object.create(null);const key=$key;const token={};globalThis.__mgreadPageJobs[key]=token;(async()=>{let json;try{const response=await(async()=>{$body})();json=JSON.stringify({ok:true,response});if(json===undefined)throw new Error('not_json');}catch(_){json=JSON.stringify({ok:false,code:'plugin_execution_failed'});}if(globalThis.__mgreadPageJobs?.[key]===token){globalThis.__mgreadPageResults[key]=json;}})();return true;})()""",
    );
    while (true) {
      _check(job);
      final raw = await _platform.executeScript(
        session.sessionId,
        "(() => {const r=globalThis.__mgreadPageResults?.[$key];if(r===undefined)return null;delete globalThis.__mgreadPageResults[$key];delete globalThis.__mgreadPageJobs?.[$key];return r;})()",
      );
      final encoded = jsonDecode(raw);
      if (encoded is String) {
        final result = jsonDecode(encoded);
        if (result is! Map<Object?, Object?> || result['ok'] != true) {
          throw WindowsBrowserSessionException(
            result is Map<Object?, Object?> && result['code'] is String
                ? result['code']! as String
                : 'plugin_execution_failed',
          );
        }
        return _stringMap(result['response']);
      }
      await Future<void>.delayed(_pollDelay);
    }
  }

  Future<void> _expirePageScriptResult(
    _WindowsBrowserSession session,
    String jobId,
  ) async {
    final key = jsonEncode(jobId);
    try {
      await _platform.executeScript(
        session.sessionId,
        "(() => {delete globalThis.__mgreadPageJobs?.[$key];delete globalThis.__mgreadPageResults?.[$key];return true;})()",
      );
    } on Object {
      // A concurrently closed or crashed page has already discarded its realm.
    }
  }
}

const _pageAsyncOperations = <String>{
  'page.evaluate',
  'page.fetch',
  'page.html',
};

final class _WindowsPageRequest {
  const _WindowsPageRequest({
    required this.body,
    required this.cdpMethod,
    required this.cdpParams,
    required this.code,
    required this.headers,
    required this.key,
    required this.method,
    required this.modifiers,
    required this.operation,
    required this.pluginId,
    required this.pluginName,
    required this.responseType,
    required this.scope,
    required this.text,
    required this.timeoutMs,
    required this.url,
    required this.visible,
    required this.x,
    required this.y,
  });

  final String? body;
  final String? cdpMethod;
  final Map<String, Object?> cdpParams;
  final String? code;
  final Map<String, String> headers;
  final String? key;
  final String method;
  final List<String> modifiers;
  final String operation;
  final String pluginId;
  final String pluginName;
  final String responseType;
  final String scope;
  final String? text;
  final int timeoutMs;
  final String? url;
  final bool visible;
  final double? x;
  final double? y;

  static _WindowsPageRequest parse(Map<String, Object?> value) {
    if (utf8.encode(jsonEncode(value)).length > _maximumRequestBytes ||
        value['version'] != 1)
      _invalid();
    final operation = _required(value, 'operation', 32);
    const operations = <String>{
      'page.open',
      'page.show',
      'page.hide',
      'page.close',
      'page.navigate',
      'page.evaluate',
      'page.cdp',
      'page.html',
      'page.fetch',
      'page.click',
      'page.input',
      'page.key',
      'page.waitText',
      'page.getUrl',
    };
    if (!operations.contains(operation)) _invalid();
    final pluginId = _required(value, 'pluginId', 160);
    if (!RegExp(r'^[a-z0-9]+(?:[._-][a-z0-9]+)+$').hasMatch(pluginId))
      _invalid();
    final pluginName = _required(value, 'pluginName', 128);
    final timeoutMs = value['timeoutMs'];
    if (timeoutMs is! int || timeoutMs < 1 || timeoutMs > _maximumTimeoutMs)
      _invalid();
    String? url;
    String? code;
    String? cdpMethod;
    var cdpParams = <String, Object?>{};
    String? text;
    String? key;
    var visible = false;
    var method = 'GET';
    var responseType = 'text';
    var scope = 'text';
    var headers = <String, String>{};
    String? body;
    double? x;
    double? y;
    var modifiers = <String>[];
    if (operation == 'page.open') {
      if (value['visible'] is! bool) _invalid();
      visible = value['visible']! as bool;
    } else if (operation == 'page.navigate' || operation == 'page.fetch') {
      url = _httpUrl(_required(value, 'url', 4096));
    }
    if (operation == 'page.evaluate')
      code = _required(value, 'code', 512 * 1024);
    if (operation == 'page.cdp') {
      cdpMethod = _required(value, 'method', 256);
      final rawParams = value['params'];
      if (rawParams is! Map<Object?, Object?> ||
          utf8.encode(jsonEncode(rawParams)).length > 512 * 1024)
        _invalid();
      cdpParams = _jsonObject(rawParams);
    }
    if (operation == 'page.fetch') {
      method = _required(value, 'method', 32);
      responseType = _required(value, 'responseType', 16);
      if (!RegExp(r'^[A-Z]+$').hasMatch(method) ||
          !const <String>{'text', 'json', 'base64'}.contains(responseType))
        _invalid();
      final rawHeaders = value['headers'];
      if (rawHeaders is! Map<Object?, Object?>) _invalid();
      headers = <String, String>{};
      for (final entry in rawHeaders.entries) {
        if (entry.key is! String ||
            entry.value is! String ||
            (entry.key! as String).isEmpty)
          _invalid();
        headers[entry.key! as String] = entry.value! as String;
      }
      if (value['body'] != null && value['body'] is! String) _invalid();
      body = value['body'] as String?;
    }
    if (operation == 'page.click') {
      x = _pageCoordinate(value['x']);
      y = _pageCoordinate(value['y']);
    }
    if (operation == 'page.input' || operation == 'page.waitText') {
      text = _required(value, 'text', 64 * 1024);
    }
    if (operation == 'page.waitText') {
      scope = _required(value, 'scope', 8);
      if (scope != 'text' && scope != 'html') _invalid();
    }
    if (operation == 'page.key') {
      key = _required(value, 'key', 16);
      const keys = <String>{
        'Enter',
        'Tab',
        'Escape',
        'ArrowUp',
        'ArrowDown',
        'ArrowLeft',
        'ArrowRight',
        'PageUp',
        'PageDown',
        'Home',
        'End',
        'Backspace',
        'Delete',
      };
      if (!keys.contains(key)) _invalid();
      final rawModifiers = value['modifiers'];
      if (rawModifiers is! List<Object?>) _invalid();
      modifiers = <String>[
        for (final item in rawModifiers)
          if (item is String &&
              const <String>{'alt', 'control', 'shift'}.contains(item))
            item
          else
            _invalid(),
      ];
      if (modifiers.toSet().length != modifiers.length) _invalid();
    }
    return _WindowsPageRequest(
      body: body,
      cdpMethod: cdpMethod,
      cdpParams: cdpParams,
      code: code,
      headers: headers,
      key: key,
      method: method,
      modifiers: modifiers,
      operation: operation,
      pluginId: pluginId,
      pluginName: pluginName,
      responseType: responseType,
      scope: scope,
      text: text,
      timeoutMs: timeoutMs,
      url: url,
      visible: visible,
      x: x,
      y: y,
    );
  }
}

Map<String, Object?> _jsonObject(Map<Object?, Object?> value) {
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String || !_isJsonValue(entry.value)) _invalid();
    result[entry.key! as String] = entry.value;
  }
  return result;
}

bool _isJsonValue(Object? value) {
  if (value == null || value is bool || value is String) return true;
  if (value is num) return value.isFinite;
  if (value is List<Object?>) return value.every(_isJsonValue);
  if (value is Map<Object?, Object?>) {
    return value.entries.every(
      (entry) => entry.key is String && _isJsonValue(entry.value),
    );
  }
  return false;
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

String _httpUrl(String value) {
  final uri = Uri.parse(value);
  if ((uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty)
    _invalid();
  return uri.toString();
}

double _pageCoordinate(Object? value) {
  if (value is! num || !value.isFinite || value < 0 || value > 100000)
    _invalid();
  return value.toDouble();
}

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

double? _finiteNumber(Object? value) {
  if (value is! num || !value.isFinite) return null;
  return value.toDouble();
}

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

String _pageHtmlScript(_WindowsBrowserJob job) {
  final origin = jsonEncode(job.request.origin);
  return """(() => {try{const finalUrl=location.href;const currentOrigin=new URL(finalUrl).origin;if(currentOrigin!==$origin)throw new Error('cross_origin');const body=document.documentElement?.outerHTML??'';if(new TextEncoder().encode(body).byteLength>${job.request.maxResponseBytes})return JSON.stringify({ok:false,code:'overloaded'});return JSON.stringify({ok:true,response:{status:200,finalUrl,headers:{'content-type':'text/html'},body}});}catch(_){return JSON.stringify({ok:false,code:'plugin_execution_failed'});}})()""";
}

String _interactionTargetScript(_WindowsBrowserRequest request) {
  final selector = jsonEncode(request.selector);
  return """(() => { try { const e=document.querySelector($selector); if(!e) return JSON.stringify({accepted:false,action:'${request.action}'}); const r=e.getBoundingClientRect(); if(!Number.isFinite(r.x)||!Number.isFinite(r.y)||r.width<=0||r.height<=0) return JSON.stringify({accepted:false,action:'${request.action}'}); return JSON.stringify({accepted:true,action:'${request.action}',x:r.x+r.width/2,y:r.y+r.height/2,width:r.width,height:r.height,devicePixelRatio:window.devicePixelRatio||1}); } catch (_) { return JSON.stringify({accepted:false,action:'${request.action}'}); } })()""";
}

String _pageFetchBody(_WindowsPageRequest request) {
  final readBody = switch (request.responseType) {
    'json' => 'await response.json()',
    'base64' =>
      "btoa(Array.from(new Uint8Array(await response.arrayBuffer()),b=>String.fromCharCode(b)).join(''))",
    _ => 'await response.text()',
  };
  return """
    const response=await fetch(${jsonEncode(request.url)},{method:${jsonEncode(request.method)},headers:JSON.parse(${jsonEncode(jsonEncode(request.headers))}),body:${request.body == null ? 'null' : jsonEncode(request.body)},credentials:'include',redirect:'follow'});
    const headers={};response.headers.forEach((v,k)=>headers[k]=v);
    const body=$readBody;return {status:response.status,url:response.url,headers,body};
  """;
}

String _pageOperationLabel(String operation) => switch (operation) {
  'page.navigate' => '正在导航',
  'page.evaluate' => '正在执行脚本',
  'page.html' => '正在获取 HTML',
  'page.fetch' => '正在发送请求',
  'page.click' => '正在点击页面',
  'page.input' => '正在输入文本',
  'page.key' => '正在发送按键',
  'page.cdp' => '正在调用 CDP',
  'page.waitText' => '正在等待页面内容',
  'page.getUrl' => '正在读取地址',
  _ => '正在探测',
};
