abstract final class ReaderCommentStrings {
  static const title = '评论';
  static const hot = '最热';
  static const newest = '最新';
  static const loading = '正在加载评论…';
  static const empty = '还没有评论';
  static const loadFailed = '评论暂时无法加载';
  static const retry = '重新加载';
  static const loadMore = '加载更多';
  static const loadingMore = '正在加载…';
  static const likes = '赞';
  static const viewAll = '查看全部';
  static const commentsCountSuffix = '条评论';
  static const close = '关闭';
  static const invalidPage = '评论分页响应不符合约定，请重试';
  static const bookTitle = '书籍评论';
  static const chapterTitle = '章节评论';
  static const paragraphTitle = '段落评论';
  static const paragraphLoading = '段落评论正在加载';
  static const paragraphLoadFailed = '段落评论加载失败，点击重试';
  static const chapterLoading = '正在加载章节评论…';
  static const chapterLoadFailed = '章节评论加载失败，点击重试';

  static String chapterSummary(int total) => '章节评论 · ${compactCount(total)}';
  static String paragraphCount(int total) => '段落评论，$total条评论';

  static String compactCount(int total) {
    if (total < 1000) return '$total';
    if (total < 10000) return '${total ~/ 1000}k+';
    if (total < 100000000) return '${total ~/ 10000}万+';
    if (total < 100000000000) return '${total ~/ 100000000}亿+';
    return '999亿+';
  }
}
