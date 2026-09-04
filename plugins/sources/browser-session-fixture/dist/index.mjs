/** Android-only HTTPS fixture for the host-owned browser.session.v1 paths. */
let context;

export function activate(value) {
  context = value;
}

export async function search(request) {
  const transport = request.query === 'android-http'
    ? 'http'
    : request.query === 'android-html' ? 'html' : 'webview';
  const response = await context.browser.sessionV1.request({
    version: 1,
    sessionKey: 'android-fixture',
    url: 'https://example.com/',
    method: 'GET',
    headers: { accept: 'text/html' },
    body: null,
    interaction: transport === 'http' ? 'allow' : 'silent',
    presentation: transport === 'http' ? 'visible' : 'hidden',
    transport,
    timeoutMs: 120000,
    maxResponseBytes: 65536,
  });
  if (response.status !== 200 || !/Example Domain/u.test(response.body)) {
    throw new Error('Android browser fixture response is invalid.');
  }
  return {
    items: [summary(`${transport}:${response.status}:${response.verificationState}`)],
    nextCursor: null,
    totalCount: 1,
  };
}

export function discover() {
  return { kind: 'document', document: { components: [] } };
}

export function searchSuggestions() {
  return { items: [], nextCursor: null };
}

export function getDetail(request) {
  return { ...summary('detail'), id: request.id, aliases: [], catalogUrl: null };
}

export function getChapters() {
  return { items: [] };
}

export function getContent(request) {
  return {
    chapterId: request.chapterId,
    contentKind: 'novel',
    title: null,
    updatedAt: null,
    text: 'fixture',
    pages: [],
  };
}

function summary(title) {
  return {
    id: `browser:${title}`,
    title,
    contentKind: 'novel',
    author: null,
    url: 'https://example.com/',
    coverUrl: null,
    description: null,
    language: null,
    status: 'unknown',
    access: 'free',
    wordCount: null,
    chapterCount: 0,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: [],
    tags: [],
    attributes: [],
  };
}
