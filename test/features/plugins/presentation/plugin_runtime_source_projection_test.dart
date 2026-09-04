/// 数据源插件管理投影测试。
///
/// 职责：
/// - 验证四种 Runtime 数据源内容类型都进入管理列表。
/// - 验证管理列表使用统一且完整的内容类型标签。
///
/// 注意：
/// - 仅覆盖不可变投影，不替代管理页 Widget 或 Runtime 契约测试。
///
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_source_projection.dart';

void main() {
  test('projects audio and video sources into the management list', () {
    const connection = PluginRuntimeConnection(
      isHealthy: true,
      nodeVersion: '24.16.0',
      runtimeVersion: 'test',
      plugins: <PluginRuntimePlugin>[
        PluginRuntimePlugin(
          activeVersion: '1.0.0',
          contentKinds: <String>['audio'],
          displayName: '音频源',
          enabled: true,
          id: 'org.example.audio',
          name: '@example/audio',
          pendingVersion: null,
          status: 'active',
        ),
        PluginRuntimePlugin(
          activeVersion: '1.0.0',
          contentKinds: <String>['video'],
          displayName: '视频源',
          enabled: true,
          id: 'org.example.video',
          name: '@example/video',
          pendingVersion: null,
          status: 'active',
        ),
        PluginRuntimePlugin(
          activeVersion: '1.0.0',
          contentKinds: <String>['video', 'novel', 'audio', 'manga'],
          displayName: '综合源',
          enabled: true,
          id: 'org.example.all',
          name: '@example/all',
          pendingVersion: null,
          status: 'active',
        ),
      ],
    );

    final sources = pluginManagementSourcesFromConnection(connection);

    expect(sources.map((source) => source.id), <String>['org.example.audio', 'org.example.video', 'org.example.all']);
    expect(sources.map((source) => source.kindLabel), <String>['音频', '视频', '小说 · 漫画 · 音频 · 视频']);
  });
}
