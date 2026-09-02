import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  _RealHttpTestBinding();

  test(
    'desktop Facade crosses the reverse WebView host boundary end to end',
    () async {
      const channel = MethodChannel('mgread_plugin_runtime/browser_session');
      var loadedUrl = 'https://example.invalid/';
      var createCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final arguments =
                (call.arguments as Map<Object?, Object?>?) ??
                const <Object?, Object?>{};
            switch (call.method) {
              case 'create':
                createCalls += 1;
                return 'native-fixture';
              case 'load':
                loadedUrl = arguments['url']! as String;
                return null;
              case 'executeScript':
                final script = arguments['script']! as String;
                if (script == 'document.readyState') {
                  return jsonEncode('complete');
                }
                if (script == 'location.href') return jsonEncode(loadedUrl);
                if (script.contains('__mgreadFetchResults?.')) {
                  return jsonEncode(
                    jsonEncode(<String, Object?>{
                      'ok': true,
                      'response': <String, Object?>{
                        'status': 200,
                        'finalUrl': loadedUrl,
                        'headers': <String, String>{
                          'content-type': 'text/html',
                        },
                        'body': 'fixture-browser-body',
                      },
                    }),
                  );
                }
                return jsonEncode('started');
              case 'show':
              case 'hide':
              case 'stop':
              case 'dispose':
                return null;
              default:
                throw PlatformException(code: 'unsupported');
            }
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final repositoryRoot = Directory.current.parent.parent;
      final dataRoot = await Directory.systemTemp.createTemp(
        'mgread-desktop-browser-bridge-',
      );
      addTearDown(() => dataRoot.delete(recursive: true));
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: repositoryRoot,
        runtimeDataRoot: dataRoot,
        developmentPluginRoot: Directory(
          '${Directory.current.path}${Platform.pathSeparator}test${Platform.pathSeparator}fixtures',
        ),
      );
      addTearDown(runtime.debugDispose);

      final result = await runtime.invoke(
        const SourceSearchInvocation(
          pluginId: 'org.mgread.browser-bridge-fixture',
          query: 'browser-session',
        ),
      );

      expect(result.items.single.title, 'browser-200');
      expect(createCalls, 1);
    },
  );
}

final class _RealHttpTestBinding extends LiveTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}
