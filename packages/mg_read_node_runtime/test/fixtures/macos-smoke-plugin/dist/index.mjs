/** Self-contained source used by the packaged macOS application smoke test. */
const summary = {
  id: "macos:fixture-book",
  title: "macOS 验收小说",
  contentKind: "novel",
  author: "MgRead",
  url: null,
  coverUrl: null,
  description: "用于检查正式 App 内 Runtime 的固定数据。",
  language: "zh-CN",
  status: "completed",
  access: "free",
  wordCount: 12,
  chapterCount: 3,
  publishedAt: null,
  updatedAt: null,
  latestChapter: null,
  categories: [],
  tags: [],
  attributes: [],
};

export function activate() {}

export function discover() {
  return {
    kind: "document",
    document: {
      components: [
        {
          type: "contentCollection",
          id: "macos-smoke",
          layout: "list",
          items: [{ content: summary, rank: null, metric: null, recommendation: null }],
          continuation: null,
        },
      ],
    },
  };
}

export function search() {
  return { items: [summary], nextCursor: null, totalCount: 1 };
}

export function getDetail(request) {
  return { ...summary, id: request.id, aliases: [], catalogUrl: null };
}

export function getChapters() {
  return {
    items: [0, 1, 2].map((order) => ({
      id: `macos:chapter-${order}`,
      title: `第 ${order + 1} 章`,
      order,
      url: null,
      volumeTitle: null,
      wordCount: 4,
      updatedAt: null,
      isLocked: false,
      attributes: [],
    })),
  };
}

export function getContent(request) {
  return {
    contentKind: "novel",
    chapterId: request.chapterId,
    title: null,
    updatedAt: null,
    text: `macOS Runtime 正文 ${request.chapterId}`,
    pages: [],
  };
}
