/** Fixed manga fixture used by the Runtime's installed-plugin contract tests. */
let context;

export function activate(nextContext) {
  context = nextContext;
}

function summary() {
  return {
    id: "manga:fixture-book",
    title: "固定漫画",
    contentKind: "manga",
    author: null,
    url: "https://example.invalid/manga/fixture-book",
    coverUrl: null,
    description: null,
    language: "zh-CN",
    status: "completed",
    access: "free",
    wordCount: null,
    chapterCount: 2,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: [],
    tags: [],
    attributes: [],
  };
}

export function discover() {
  return { kind: "document", document: { components: [] } };
}

export function search() {
  return { items: [summary()], nextCursor: null, totalCount: 1 };
}

export function getDetail() {
  return { ...summary(), aliases: [], catalogUrl: null };
}

export function getChapters() {
  return {
    items: [1, 2].map((number, index) => ({
      id: `manga:fixture-book:chapter-${number}`,
      title: `第 ${number} 话`,
      order: index,
      url: null,
      volumeTitle: null,
      wordCount: null,
      updatedAt: null,
      isLocked: false,
      attributes: [],
    })),
  };
}

export function getContent(request) {
  const durable = request.chapterId.endsWith("chapter-2");
  const pages = [0, 1].map((index) => ({
    id: `${request.chapterId}:page-${index}`,
    index,
    url: durable
      ? `https://example.invalid/manga/fixture-book/${request.chapterId}/page-${index}.png`
      : context.resource.proxy({
          kind: "image",
          url: `https://fixture.invalid/${request.chapterId}/page-${index}.png`,
          headers: {
            Accept: "image/png",
            Referer: "https://example.invalid/manga/fixture-book",
          },
        }),
    mimeType: "image/png",
    width: 1,
    height: 1,
    resourcePolicy: durable ? "durable" : "sessionOnly",
    expiresAt: null,
  }));
  return {
    contentKind: "manga",
    chapterId: request.chapterId,
    title: null,
    updatedAt: null,
    text: null,
    pages,
  };
}
