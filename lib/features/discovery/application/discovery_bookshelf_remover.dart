/// 发现与搜索详情的书架移除编排。
///
/// 职责：
/// - 用同源标题成员索引解析稳定书架 ID。
/// - 在共享书架删除用例执行期间维护发现/搜索的乐观成员投影。
///
/// 注意：
/// - 持久化、首页投影和诊断由注入的共享删除用例负责。
/// - 持久化失败时必须恢复成员投影，不能把失败显示成已移出。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/features/discovery/application/bookshelf_membership.dart';

abstract interface class DiscoveryBookshelfRemover {
  Future<void> remove({required String pluginId, required String title});
}

typedef BookshelfBookRemoval = Future<void> Function(String bookId);

final class CoordinatedDiscoveryBookshelfRemover implements DiscoveryBookshelfRemover {
  const CoordinatedDiscoveryBookshelfRemover({required this.membership, required this.removeBook});

  final BookshelfMembershipController membership;
  final BookshelfBookRemoval removeBook;

  @override
  Future<void> remove({required String pluginId, required String title}) async {
    final entry = await membership.entryWhenReady(pluginId: pluginId, title: title);
    if (entry == null) throw StateError('Bookshelf membership is unavailable.');

    membership.markRemoved(entry);
    try {
      await removeBook(entry.itemId);
    } on Object {
      membership.markAdded(itemId: entry.itemId, pluginId: entry.pluginId, title: entry.title);
      rethrow;
    }
  }
}

final discoveryBookshelfRemoverProvider = Provider<DiscoveryBookshelfRemover?>((Ref ref) => null);
