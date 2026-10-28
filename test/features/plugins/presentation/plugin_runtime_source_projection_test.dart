/// 数据源插件管理投影测试。
///
/// 职责：
/// - 验证四种 Runtime 数据源内容类型都进入管理列表。
/// - 验证管理列表使用统一且完整的内容类型标签。
/// - 验证 R18 来源标记进入投影标签。
///
/// 注意：
/// - 仅覆盖不可变投影，不替代管理页 Widget 或 Runtime 契约测试。
///
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_source_projection.dart';

void main() {
  for (final state in ['disabled', 'invalid']) {
    test('keeps $state source visible for management and blocks discovery/search', () {
      final source = PluginRuntimePlugin(
        activeVersion: '1.0.0',
        contentKinds: const ['audio'],
        displayName: '听书中国',
        enabled: true,
        id: 'org.test.unavailable',
        name: 'test',
        pendingVersion: null,
        status: 'active',
        sourceState: state,
        sourceStateReason: '网站已禁用播放',
      );
      final rows = pluginManagementSourcesFromConnection(
        PluginRuntimeConnection(isHealthy: true, nodeVersion: 'test', runtimeVersion: 'test', plugins: [source]),
      );
      expect(rows.single.canOpen, isFalse);
      expect(rows.single.enabled, isTrue);
      expect(rows.single.kindLabel, contains(state == 'invalid' ? '已失效' : '已禁用'));
      expect(rows.single.description, contains('网站已禁用播放'));
    });
  }

  test('projects audio and video sources into the management list', () {
    const connection = PluginRuntimeConnection(
      isHealthy: true,
      nodeVersion: '26.10.0',
      runtimeVersion: 'test',
      plugins: <PluginRuntimePlugin>[
        PluginRuntimePlugin(
          activeVersion: '1.0.0',
          contentKinds: <String>['audio'],
          displayName: '音频源',
          description: '  收录有声书专辑与电台节目，按专辑和章节组织音频内容。  ',
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
    expect(sources.first.description, '收录有声书专辑与电台节目，按专辑和章节组织音频内容。');
    expect(sources[1].description, '暂无网站简介');
    expect(sources[2].description, '暂无网站简介');
  });

  test('projects the r18 marker into metadata labels', () {
    const connection = PluginRuntimeConnection(
      isHealthy: true,
      nodeVersion: '26.10.0',
      runtimeVersion: 'test',
      plugins: <PluginRuntimePlugin>[
        PluginRuntimePlugin(
          activeVersion: '1.0.0',
          contentKinds: <String>['manga'],
          displayName: '漫画源',
          enabled: true,
          id: 'org.example.r18',
          name: '@example/r18',
          pendingVersion: null,
          status: 'active',
          r18: true,
        ),
      ],
    );

    final sources = pluginManagementSourcesFromConnection(connection);

    expect(sources.single.r18, isTrue);
    expect(sources.single.kindLabel, '漫画 · R18');
  });
}
