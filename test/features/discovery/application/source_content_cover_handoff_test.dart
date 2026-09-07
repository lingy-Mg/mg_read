/// 数据源封面交接纯数据测试。
///
/// 职责：
/// - 验证 Runtime 详情替换摘要时保留宿主本地封面。
/// - 验证不同内容 ID 不会相互污染封面。
///
/// 注意：
/// - 本测试不读取 Runtime、网络或持久化。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/discovery/application/source_content_cover_handoff.dart';

void main() {
  for (final kind in PluginContentKind.values) {
    test('preserves entry cover for ${kind.code} details', () {
      final fallback = _summary(
        kind: kind,
        coverUrl: _coverUrl,
        coverBytes: _coverBytes,
        coverOrientation: PluginCoverOrientation.landscape,
      );
      final detail = _detail(_summary(kind: kind, coverUrl: null, coverBytes: null));

      final covered = preserveSourceContentCover(detail: detail, fallbackSummary: fallback);

      expect(covered.summary.coverUrl, _coverUrl);
      expect(covered.summary.coverBytes, same(_coverBytes));
      expect(covered.summary.coverOrientation, PluginCoverOrientation.landscape);
    });
  }

  test('keeps destination cover authoritative and ignores a different content id', () {
    final destinationBytes = <int>[9, 8, 7];
    final detail = _detail(_summary(kind: PluginContentKind.video, coverUrl: _detailCoverUrl, coverBytes: destinationBytes));

    final covered = preserveSourceContentCover(
      detail: detail,
      fallbackSummary: _summary(id: 'another-content', kind: PluginContentKind.video, coverUrl: _coverUrl, coverBytes: _coverBytes),
    );

    expect(covered, same(detail));
    expect(covered.summary.coverUrl, _detailCoverUrl);
    expect(covered.summary.coverBytes, same(destinationBytes));
  });
}

const _coverBytes = <int>[1, 2, 3, 4];
final _coverUrl = Uri.parse('https://covers.example/entry.png');
final _detailCoverUrl = Uri.parse('https://covers.example/detail.png');

PluginContentDetail _detail(PluginContentSummary summary) =>
    PluginContentDetail(pluginId: 'fixture-source', sourceName: '测试来源', summary: summary, aliases: const <String>[], catalogUrl: null);

PluginContentSummary _summary({
  String id = 'content-1',
  required PluginContentKind kind,
  required Uri? coverUrl,
  required List<int>? coverBytes,
  PluginCoverOrientation coverOrientation = PluginCoverOrientation.portrait,
}) => PluginContentSummary(
  id: id,
  title: '测试内容',
  contentKind: kind,
  coverOrientation: coverOrientation,
  author: null,
  url: null,
  coverUrl: coverUrl,
  coverBytes: coverBytes,
  description: null,
  language: null,
  status: PluginContentStatus.unknown,
  access: PluginAccessKind.unknown,
  wordCount: null,
  chapterCount: 1,
  publishedAt: null,
  updatedAt: null,
  latestChapter: null,
  categories: const <String>[],
  tags: const <String>[],
  attributes: const <PluginContentAttribute>[],
);
