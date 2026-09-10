import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:mgread_plugin_runtime/src/windows_browser_session_host.dart';

void main() {
  test(
    'one source reuses one WebView for hidden and visible browser fetch',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mgread-windows-browser-',
      );
      addTearDown(() => root.delete(recursive: true));
      final platform = _FakeBrowserPlatform();
      final host = WindowsBrowserSessionHost(root, platform: platform);
      addTearDown(host.dispose);

      final hidden = await host.request(
        jobId: 's:hidden',
        deadlineUnixMs: DateTime.now()
            .add(const Duration(seconds: 5))
            .millisecondsSinceEpoch,
        raw: _request(presentation: 'hidden', transport: 'webview'),
      );
      final visible = await host.request(
        jobId: 's:visible',
        deadlineUnixMs: DateTime.now()
            .add(const Duration(seconds: 5))
            .millisecondsSinceEpoch,
        raw: _request(presentation: 'visible', transport: 'webview'),
      );

      expect(hidden['body'], 'fixture-browser-body');
      expect(visible['body'], 'fixture-browser-body');
      expect(platform.createCalls, 1);
      expect(platform.showCalls, 1);
      expect(platform.loadedUrls, hasLength(2));
    },
  );

  test(
    'recreates a manually closed visible WebView on the next request',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mgread-windows-recreate-',
      );
      addTearDown(() => root.delete(recursive: true));
      final platform = _FakeBrowserPlatform(failNextShow: true);
      final host = WindowsBrowserSessionHost(root, platform: platform);
      addTearDown(host.dispose);

      final result = await host.request(
        jobId: 's:recreate',
        deadlineUnixMs: DateTime.now()
            .add(const Duration(seconds: 5))
            .millisecondsSinceEpoch,
        raw: _request(presentation: 'visible', transport: 'webview'),
      );

      expect(result['body'], 'fixture-browser-body');
      expect(platform.createCalls, 2);
      expect(platform.showCalls, 2);
    },
  );

  test(
    'HTTP mode keeps Cookie and UA inside the Windows host and writes Set-Cookie back',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mgread-windows-http-',
      );
      addTearDown(() => root.delete(recursive: true));
      final platform = _FakeBrowserPlatform();
      final responseHeaders = _FakeHeaders()
        ..set(HttpHeaders.contentTypeHeader, 'text/html; charset=utf-8')
        ..add(
          HttpHeaders.setCookieHeader,
          'session=updated; Path=/; Secure; HttpOnly',
        );
      final response = _FakeResponse(
        200,
        responseHeaders,
        utf8.encode('fixture-http-body'),
      );
      final request = _FakeRequest(response);
      final client = _FakeHttpClient(request);
      final host = WindowsBrowserSessionHost(
        root,
        platform: platform,
        httpClientFactory: () => client,
      );
      addTearDown(host.dispose);

      final result = await host.request(
        jobId: 's:http',
        deadlineUnixMs: DateTime.now()
            .add(const Duration(seconds: 5))
            .millisecondsSinceEpoch,
        raw: _request(presentation: 'hidden', transport: 'http'),
      );

      expect(result['body'], 'fixture-http-body');
      expect(
        request.headers.value(HttpHeaders.cookieHeader),
        'cf_clearance=fixture',
      );
      expect(
        request.headers.value(HttpHeaders.userAgentHeader),
        'fixture-agent',
      );
      expect(platform.writtenCookies.single['name'], 'session');
      expect(platform.showCalls, 0);
    },
  );

  test(
    'WebView fetch returns an error response for the source to inspect',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mgread-windows-fetch-cf-',
      );
      addTearDown(() => root.delete(recursive: true));
      final platform = _FakeBrowserPlatform(fetchErrorOnce: true);
      final host = WindowsBrowserSessionHost(root, platform: platform);
      addTearDown(host.dispose);

      final result = await host.request(
        jobId: 's:fetch-cf',
        deadlineUnixMs: DateTime.now()
            .add(const Duration(seconds: 5))
            .millisecondsSinceEpoch,
        raw: _request(presentation: 'visible', transport: 'webview'),
      );

      expect(result['body'], '403 Forbidden');
      expect(result['status'], 403);
      expect(platform.createCalls, 1);
      expect(platform.showCalls, 1);
      expect(platform.loadedUrls, hasLength(1));
    },
  );

  test('HTML mode returns the current page document', () async {
    final root = await Directory.systemTemp.createTemp('mgread-windows-html-');
    addTearDown(() => root.delete(recursive: true));
    final platform = _FakeBrowserPlatform();
    final host = WindowsBrowserSessionHost(root, platform: platform);
    addTearDown(host.dispose);

    final result = await host.request(
      jobId: 's:html',
      deadlineUnixMs: DateTime.now()
          .add(const Duration(seconds: 5))
          .millisecondsSinceEpoch,
      raw: _request(presentation: 'visible', transport: 'html'),
    );

    expect(result['body'], '<html><body>fixture</body></html>');
    expect(result['status'], 200);
  });

  test('WebView interactions stay scoped to the source session', () async {
    final root = await Directory.systemTemp.createTemp(
      'mgread-windows-actions-',
    );
    addTearDown(() => root.delete(recursive: true));
    final platform = _FakeBrowserPlatform();
    final host = WindowsBrowserSessionHost(root, platform: platform);
    addTearDown(host.dispose);

    final coordinates = await host.request(
      jobId: 's:coordinates',
      deadlineUnixMs: DateTime.now()
          .add(const Duration(seconds: 5))
          .millisecondsSinceEpoch,
      raw: _interactionRequest('coordinates'),
    );
    final input = await host.request(
      jobId: 's:input',
      deadlineUnixMs: DateTime.now()
          .add(const Duration(seconds: 5))
          .millisecondsSinceEpoch,
      raw: _interactionRequest('native-input', text: 'fixture-input'),
    );
    final click = await host.request(
      jobId: 's:click',
      deadlineUnixMs: DateTime.now()
          .add(const Duration(seconds: 5))
          .millisecondsSinceEpoch,
      raw: _interactionRequest('control-click'),
    );

    expect(coordinates, containsPair('action', 'coordinates'));
    expect(coordinates['x'], 12);
    expect(input, containsPair('action', 'native-input'));
    expect(click, containsPair('action', 'control-click'));
    expect(platform.createCalls, 1);
    expect(platform.loadedUrls, hasLength(3));
    expect(platform.dispatchMouseInputCalls, 2);
    expect(platform.insertedTexts, <String>['fixture-input']);
  });

  test(
    'resident WebViews stay capped during concurrent source creation',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mgread-windows-resident-cap-',
      );
      addTearDown(() => root.delete(recursive: true));
      final platform = _FakeBrowserPlatform(
        createDelay: const Duration(milliseconds: 10),
      );
      final host = WindowsBrowserSessionHost(root, platform: platform);
      addTearDown(host.dispose);

      await Future.wait(<Future<Map<String, Object?>>>[
        for (var index = 0; index < 9; index += 1)
          host.request(
            jobId: 's:cap-$index',
            deadlineUnixMs: DateTime.now()
                .add(const Duration(seconds: 10))
                .millisecondsSinceEpoch,
            raw: <String, Object?>{
              ..._request(presentation: 'hidden', transport: 'webview'),
              'pluginId': 'org.mgread.fixture$index',
            },
          ),
      ]);

      expect(platform.createCalls, 9);
      expect(platform.disposeCalls, 1);
    },
  );

  test(
    'single-page API reuses its page and supports control and native input',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mgread-windows-page-',
      );
      addTearDown(() => root.delete(recursive: true));
      final platform = _FakeBrowserPlatform();
      final host = WindowsBrowserSessionHost(root, platform: platform);
      addTearDown(host.dispose);
      final deadline = DateTime.now()
          .add(const Duration(seconds: 5))
          .millisecondsSinceEpoch;

      await host.request(
        jobId: 'p:open',
        deadlineUnixMs: deadline,
        raw: _page('page.open', <String, Object?>{'visible': true}),
      );
      await host.request(
        jobId: 'p:navigate',
        deadlineUnixMs: deadline,
        raw: _page('page.navigate', <String, Object?>{
          'url': 'https://example.com/page',
        }),
      );
      final value = await host.request(
        jobId: 'p:eval',
        deadlineUnixMs: deadline,
        raw: _page('page.evaluate', <String, Object?>{
          'code': 'await Promise.resolve(); return {ok:true};',
        }),
      );
      final cdp = await host.request(
        jobId: 'p:cdp',
        deadlineUnixMs: deadline,
        raw: _page('page.cdp', <String, Object?>{
          'method': 'Input.dispatchKeyEvent',
          'params': <String, Object?>{'type': 'keyDown', 'key': 'Enter'},
        }),
      );
      final html = await host.request(
        jobId: 'p:html',
        deadlineUnixMs: deadline,
        raw: _page('page.html'),
      );
      await host.request(
        jobId: 'p:click',
        deadlineUnixMs: deadline,
        raw: _page('page.click', <String, Object?>{'x': 12, 'y': 18}),
      );
      await host.request(
        jobId: 'p:input',
        deadlineUnixMs: deadline,
        raw: _page('page.input', <String, Object?>{'text': 'native'}),
      );
      await host.request(
        jobId: 'p:key',
        deadlineUnixMs: deadline,
        raw: _page('page.key', <String, Object?>{
          'key': 'Enter',
          'modifiers': <String>['control'],
        }),
      );
      await host.request(
        jobId: 'p:hide',
        deadlineUnixMs: deadline,
        raw: _page('page.hide'),
      );
      await host.request(
        jobId: 'p:show',
        deadlineUnixMs: deadline,
        raw: _page('page.show'),
      );
      await host.request(
        jobId: 'p:close',
        deadlineUnixMs: deadline,
        raw: _page('page.close'),
      );

      expect(value['value'], <String, Object?>{'ok': true});
      expect(cdp['value'], <String, Object?>{'protocol': 'accepted'});
      expect(html['html'], '<html><body>live</body></html>');
      expect(platform.createCalls, 1);
      expect(platform.dispatchMouseInputCalls, 1);
      expect(platform.insertedTexts, <String>['native']);
      expect(platform.dispatchedKeys, <String>['Enter']);
      expect(platform.cdpCalls, <String>[
        'Input.dispatchKeyEvent:{"type":"keyDown","key":"Enter"}',
      ]);
      expect(platform.hideCalls, 1);
      expect(platform.disposeCalls, 1);
    },
  );

  test('timed out page scripts revoke late result writes', () async {
    final root = await Directory.systemTemp.createTemp(
      'mgread-windows-page-timeout-',
    );
    addTearDown(() => root.delete(recursive: true));
    final platform = _FakeBrowserPlatform(holdPageResult: true);
    final host = WindowsBrowserSessionHost(root, platform: platform);
    addTearDown(host.dispose);
    await host.request(
      jobId: 'p:open-timeout',
      deadlineUnixMs: DateTime.now()
          .add(const Duration(seconds: 5))
          .millisecondsSinceEpoch,
      raw: _page('page.open', <String, Object?>{'visible': false}),
    );

    await expectLater(
      host.request(
        jobId: 'p:evaluate-timeout',
        deadlineUnixMs: DateTime.now()
            .add(const Duration(milliseconds: 50))
            .millisecondsSinceEpoch,
        raw: _page('page.evaluate', <String, Object?>{
          'code': 'await new Promise(() => {});',
        }),
      ),
      throwsA(
        isA<WindowsBrowserSessionException>().having(
          (error) => error.code,
          'code',
          'timeout',
        ),
      ),
    );
    expect(platform.pageJobGuarded, isTrue);
    expect(platform.pageJobActive, isFalse);

    platform.completeHeldPageScript();
    expect(platform.pageResult, isNull);
  });

  test(
    'debug mode pins one source WebView visible and hides without destroying it',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mgread-windows-debug-',
      );
      addTearDown(() => root.delete(recursive: true));
      final platform = _FakeBrowserPlatform();
      final host = WindowsBrowserSessionHost(root, platform: platform);
      addTearDown(host.dispose);
      final deadline = DateTime.now()
          .add(const Duration(seconds: 5))
          .millisecondsSinceEpoch;

      final result = await host.request(
        jobId: 'p:debug',
        deadlineUnixMs: deadline,
        raw: _page('debug', <String, Object?>{'action': 'enter'}),
      );
      await host.request(
        jobId: 'p:open-hidden',
        deadlineUnixMs: deadline,
        raw: _page('page.open', <String, Object?>{'visible': false}),
      );
      await host.request(
        jobId: 'p:hide',
        deadlineUnixMs: deadline,
        raw: _page('page.hide'),
      );

      expect(result, <String, Object?>{
        'accepted': true,
        'action': 'enter',
        'version': 1,
      });
      expect(platform.createCalls, 1);
      expect(platform.showCalls, 2);
      expect(platform.hideCalls, 0);
    },
  );
}

Map<String, Object?> _page(
  String operation, [
  Map<String, Object?> extra = const <String, Object?>{},
]) => <String, Object?>{
  'version': 1,
  'operation': operation,
  'pluginId': 'org.mgread.fixture',
  'pluginName': 'Fixture Source',
  'timeoutMs': 5000,
  ...extra,
};

Map<String, Object?> _request({
  required String presentation,
  required String transport,
}) => <String, Object?>{
  'version': 1,
  'pluginId': 'org.mgread.fixture',
  'sessionKey': 'fixture',
  'url': 'https://example.com/protected',
  'method': 'GET',
  'headers': <String, String>{'accept': 'text/html'},
  'body': null,
  'interaction': 'allow',
  'presentation': presentation,
  'transport': transport,
  'timeoutMs': 5000,
  'maxResponseBytes': 4096,
};

Map<String, Object?> _interactionRequest(String action, {String? text}) =>
    <String, Object?>{
      'operation': 'interaction',
      'action': action,
      'version': 1,
      'pluginId': 'org.mgread.fixture',
      'sessionKey': 'fixture',
      'url': 'https://example.com/protected',
      'selector': '#fixture-control',
      'presentation': 'hidden',
      'timeoutMs': 5000,
      if (text != null) 'text': text,
    };

final class _FakeBrowserPlatform implements WindowsBrowserPlatform {
  _FakeBrowserPlatform({
    this.createDelay = Duration.zero,
    this.failNextShow = false,
    this.fetchErrorOnce = false,
    this.holdPageResult = false,
  });

  final Duration createDelay;
  bool failNextShow;
  bool fetchErrorOnce;
  final bool holdPageResult;
  int createCalls = 0;
  int disposeCalls = 0;
  int showCalls = 0;
  int dispatchMouseInputCalls = 0;
  final List<String> cdpCalls = <String>[];
  int hideCalls = 0;
  final List<String> insertedTexts = <String>[];
  final List<String> dispatchedKeys = <String>[];
  final List<String> loadedUrls = <String>[];
  final List<Map<String, Object?>> writtenCookies = <Map<String, Object?>>[];
  Map<String, Object?>? pageResult;
  bool pageJobActive = false;
  bool pageJobGuarded = false;

  void completeHeldPageScript() {
    if (pageJobActive || !pageJobGuarded) {
      pageResult = <String, Object?>{'value': 'late'};
    }
  }

  @override
  Future<String> create({
    required String pluginId,
    required String pluginName,
    required String profilePath,
  }) async {
    await Future<void>.delayed(createDelay);
    createCalls += 1;
    return 'native:$pluginId';
  }

  @override
  Future<void> dispose(String sessionId) async => disposeCalls += 1;

  @override
  Future<void> dispatchMouseInput(
    String sessionId, {
    required double x,
    required double y,
    required double devicePixelRatio,
  }) async {
    dispatchMouseInputCalls += 1;
  }

  @override
  Future<String> callDevToolsProtocolMethod(
    String sessionId, {
    required String method,
    required String paramsJson,
  }) async {
    cdpCalls.add('$method:$paramsJson');
    return jsonEncode(<String, Object?>{'protocol': 'accepted'});
  }

  @override
  Future<void> insertText(String sessionId, String text) async {
    insertedTexts.add(text);
  }

  @override
  Future<void> dispatchKey(
    String sessionId, {
    required String key,
    required List<String> modifiers,
  }) async => dispatchedKeys.add(key);

  @override
  Future<String> executeScript(String sessionId, String script) async {
    if (script == 'document.readyState') return jsonEncode('complete');
    if (script.startsWith('window.__mgreadNavigationNonce=')) {
      return jsonEncode(true);
    }
    if (script.contains('readyState:document.readyState') &&
        script.contains('__mgreadNavigationNonce')) {
      return jsonEncode(
        jsonEncode(<String, Object?>{'readyState': 'complete', 'nonce': null}),
      );
    }
    if (script == 'location.href')
      return jsonEncode('https://example.com/page');
    if (script == 'window.devicePixelRatio||1') return jsonEncode(1);
    if (script ==
        "JSON.stringify({html:document.documentElement?.outerHTML??''})") {
      return jsonEncode(
        jsonEncode(<String, Object?>{'html': '<html><body>live</body></html>'}),
      );
    }
    if (script.contains('__mgreadPageResults??=')) {
      pageJobActive = true;
      pageJobGuarded = script.contains(
        'globalThis.__mgreadPageJobs?.[key]===token',
      );
      if (!holdPageResult) {
        pageResult = script.contains('new AsyncFunction')
            ? <String, Object?>{
                'value': <String, Object?>{'ok': true},
              }
            : <String, Object?>{};
      }
      return jsonEncode(true);
    }
    if (script.startsWith('(() => {delete globalThis.__mgreadPageJobs?.[')) {
      pageJobActive = false;
      pageResult = null;
      return jsonEncode(true);
    }
    if (script.contains('__mgreadPageResults?.')) {
      final result = pageResult;
      pageResult = null;
      if (result != null) pageJobActive = false;
      return jsonEncode(
        result == null
            ? null
            : jsonEncode(<String, Object?>{'ok': true, 'response': result}),
      );
    }
    if (script == 'location.origin') return jsonEncode('https://example.com');
    if (script == 'navigator.userAgent') return jsonEncode('fixture-agent');
    if (script.contains("action:'coordinates'")) {
      return jsonEncode(
        jsonEncode(<String, Object?>{
          'accepted': true,
          'action': 'coordinates',
          'x': 12,
          'y': 18,
          'width': 80,
          'height': 24,
        }),
      );
    }
    if (script.contains("action:'native-input'")) {
      return jsonEncode(
        jsonEncode(<String, Object?>{
          'accepted': true,
          'action': 'native-input',
          'x': 12,
          'y': 18,
          'width': 80,
          'height': 24,
          'devicePixelRatio': 1,
        }),
      );
    }
    if (script.contains("action:'control-click'")) {
      return jsonEncode(
        jsonEncode(<String, Object?>{
          'accepted': true,
          'action': 'control-click',
          'x': 12,
          'y': 18,
          'width': 80,
          'height': 24,
          'devicePixelRatio': 1,
        }),
      );
    }
    if (script.contains('__mgreadFetchResults?.')) {
      if (fetchErrorOnce) {
        fetchErrorOnce = false;
        return jsonEncode(
          jsonEncode(<String, Object?>{
            'ok': true,
            'response': <String, Object?>{
              'status': 403,
              'finalUrl': 'https://example.com/protected',
              'headers': <String, String>{'content-type': 'text/html'},
              'body': '403 Forbidden',
            },
          }),
        );
      }
      return jsonEncode(
        jsonEncode(<String, Object?>{
          'ok': true,
          'response': <String, Object?>{
            'status': 200,
            'finalUrl': 'https://example.com/protected',
            'headers': <String, String>{'content-type': 'text/html'},
            'body': 'fixture-browser-body',
          },
        }),
      );
    }
    if (script.contains('document.documentElement?.outerHTML')) {
      return jsonEncode(
        jsonEncode(<String, Object?>{
          'ok': true,
          'response': <String, Object?>{
            'status': 200,
            'finalUrl': 'https://example.com/protected',
            'headers': <String, String>{'content-type': 'text/html'},
            'body': '<html><body>fixture</body></html>',
          },
        }),
      );
    }
    return jsonEncode('started');
  }

  @override
  Future<List<Map<String, Object?>>> getCookies(
    String sessionId,
    String url,
  ) async => <Map<String, Object?>>[
    <String, Object?>{'name': 'cf_clearance', 'value': 'fixture'},
  ];

  @override
  Future<void> hide(String sessionId) async => hideCalls += 1;

  @override
  Future<void> load(String sessionId, String url) async => loadedUrls.add(url);

  @override
  Future<void> setCookie(String sessionId, Map<String, Object?> cookie) async =>
      writtenCookies.add(cookie);

  @override
  Future<void> show(String sessionId) async {
    showCalls += 1;
    if (failNextShow) {
      failNextShow = false;
      throw PlatformException(code: 'unsupported');
    }
  }

  @override
  Future<void> stop(String sessionId) async {}

  @override
  Future<void> updateStatus(String sessionId, String status) async {}
}

final class _FakeHttpClient extends Fake implements HttpClient {
  _FakeHttpClient(this.request);

  final _FakeRequest request;

  @override
  Duration? connectionTimeout;

  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    request.method = method;
    request.url = url;
    return request;
  }

  @override
  void close({bool force = false}) {}
}

final class _FakeRequest extends Fake implements HttpClientRequest {
  _FakeRequest(this.response);

  final _FakeResponse response;
  @override
  final _FakeHeaders headers = _FakeHeaders();
  @override
  String method = 'GET';
  Uri? url;
  String body = '';

  @override
  bool followRedirects = true;

  @override
  void write(Object? object) => body += '$object';

  @override
  Future<HttpClientResponse> close() async => response;
}

final class _FakeResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeResponse(this.statusCode, this.headers, this.bytes);

  @override
  final int statusCode;
  @override
  final _FakeHeaders headers;
  final List<int> bytes;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeHeaders extends Fake implements HttpHeaders {
  final Map<String, List<String>> _values = <String, List<String>>{};

  @override
  ContentType? get contentType {
    final value = this.value(HttpHeaders.contentTypeHeader);
    return value == null ? null : ContentType.parse(value);
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = <String>['$value'];
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _values.putIfAbsent(name.toLowerCase(), () => <String>[]).add('$value');
  }

  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  @override
  String? value(String name) => _values[name.toLowerCase()]?.join(', ');
}
