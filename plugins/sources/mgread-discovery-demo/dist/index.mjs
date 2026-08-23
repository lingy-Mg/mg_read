let context;

export async function activate(nextContext) {
  context = nextContext;
  context.log.info('demo_activated');
}

export async function discover(request) {
  requireContext().log.info('demo_discover');
  if (request.collectionId !== null) return appendCategory(request);
  if (request.target?.startsWith('category:') === true) return categoryDocument(request.target);
  return homeDocument(request.target);
}

export async function search(request) {
  requireContext().log.info('demo_search');
  return { items: [book(`search:${request.query}`, '搜索演示结果')], nextCursor: null, totalCount: 1 };
}

export async function getDetail(request) {
  requireContext().log.info('demo_detail');
  if (typeof request?.id !== 'string' || !request.id.startsWith('demo:') || request.id.length === 5) {
    throw new Error('Invalid demonstration content id.');
  }
  return { ...book(request.id.slice(5), '组件演示书籍'), aliases: [], catalogUrl: null };
}

export async function getChapters(request) {
  requireContext().log.info('demo_chapters');
  return {
    items: [{ id: `${request.id}:chapter-1`, title: '第一章', order: 0, url: null, volumeTitle: null, wordCount: 1200, updatedAt: null, isLocked: false, attributes: [] }],
    nextCursor: null,
    totalCount: 1,
  };
}

export async function getContent(request) {
  requireContext().log.info('demo_content');
  return { chapterId: request.chapterId, contentKind: 'novel', title: '第一章', updatedAt: null, text: '这是内置发现组件演示书源的离线正文。', pages: [] };
}

function homeDocument(target) {
  const selectedTabId = target === 'tab:ranking' ? 'ranking' : 'recommend';
  return {
    kind: 'document',
    document: {
      components: [
        { type: 'tabs', id: 'demo-tabs', selectedTabId, tabs: [
          { id: 'recommend', label: '推荐', target: 'tab:recommend' },
          { id: 'ranking', label: '排行', target: 'tab:ranking' },
          { id: 'complete', label: '完本', target: 'tab:complete' },
        ] },
        { type: 'section', id: 'demo-featured-section', title: '精选组件', subtitle: '书源按树形结构声明内容，不控制宿主样式。', children: [
          { type: 'contentCollection', id: 'demo-featured', layout: 'featured', continuation: null, items: [item('featured-1', '星海余烬', '编辑精选的 Hero 组件')] },
          { type: 'divider', id: 'demo-featured-divider' },
          { type: 'contentCollection', id: 'demo-carousel', layout: 'carousel', continuation: null, items: [
            item('carousel-1', '雾中旅人', '横滑展示'), item('carousel-2', '北境来信', '横滑展示'), item('carousel-3', '无声长夜', '横滑展示'), item('carousel-4', '群星回响', '横滑展示'),
          ] },
        ] },
        { type: 'group', id: 'demo-nested-group', layout: 'vertical', children: [
          { type: 'text', id: 'demo-nested-text', text: '以下展示 section 与 group 的递归组合。' },
          { type: 'group', id: 'demo-horizontal-group', layout: 'horizontal', children: [
            { type: 'text', id: 'demo-horizontal-left', text: '横向 group 左侧节点' },
            { type: 'text', id: 'demo-horizontal-right', text: '横向 group 右侧节点' },
          ] },
          { type: 'group', id: 'demo-grid-group', layout: 'grid', children: [
            { type: 'section', id: 'demo-ranking-section', title: '热度排行', subtitle: null, children: [
              { type: 'contentCollection', id: 'demo-ranking', layout: 'ranking', continuation: null, items: [
                item('rank-1', '深空档案', null, 1), item('rank-2', '雨巷旧事', null, 2), item('rank-3', '边界旅社', null, 3),
              ] },
            ] },
            { type: 'section', id: 'demo-category-section', title: '多级分类', subtitle: '进入任一分类可体验返回与分页。', children: [
              { type: 'categoryCollection', id: 'demo-categories', layout: 'grid', categories: [
                category('fantasy', '幻想'), category('mystery', '悬疑'), category('history', '历史'), category('urban', '都市'), category('scifi', '科幻'), category('romance', '言情'),
              ] },
            ] },
          ] },
        ] },
        { type: 'section', id: 'demo-list-section', title: '编辑推荐', subtitle: null, children: [
          { type: 'contentCollection', id: 'demo-list', layout: 'list', continuation: null, items: [item('list-1', '最后一座灯塔', '列表组件复用现有编辑推荐卡片'), item('list-2', '冰原观测站', '第二个列表项目')] },
        ] },
      ],
    },
  };
}

function categoryDocument(target) {
  const key = target.slice('category:'.length);
  return {
    kind: 'document',
    document: { components: [
      { type: 'section', id: `category-section:${key}`, title: `${categoryTitle(key)}分类`, subtitle: '此页的内容集合支持定向追加。', children: [
        { type: 'contentCollection', id: `category-books:${key}`, layout: 'list', continuation: { target, cursor: 'page:2' }, items: [
          item(`${key}-1`, `${categoryTitle(key)}之书 I`, '分类第一页'), item(`${key}-2`, `${categoryTitle(key)}之书 II`, '分类第一页'),
        ] },
      ] },
    ] },
  };
}

function appendCategory(request) {
  const key = request.target?.slice('category:'.length) ?? 'unknown';
  if (request.collectionId !== `category-books:${key}` || request.cursor !== 'page:2') {
    throw new Error('Invalid demonstration continuation.');
  }
  return {
    kind: 'append',
    collectionId: request.collectionId,
    continuation: null,
    items: [item(`${key}-3`, `${categoryTitle(key)}之书 III`, '分类第二页'), item(`${key}-4`, `${categoryTitle(key)}之书 IV`, '分类第二页')],
  };
}

function category(id, title) {
  return { id: `category:${id}`, title, target: `category:${id}`, count: 4, url: null };
}

function item(id, title, recommendation, rank = null) {
  return { content: book(id, title), rank, metric: rank === null ? null : { label: '热度', value: String(1000 - rank * 10) }, recommendation };
}

function book(id, title) {
  return {
    id: `demo:${id}`,
    title,
    contentKind: 'novel',
    author: 'MgRead 演示书源',
    url: null,
    coverUrl: null,
    description: '固定离线模拟数据，用于验证发现组件树。',
    language: 'zh-CN',
    status: 'ongoing',
    access: 'free',
    wordCount: 100000,
    chapterCount: 1,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: ['演示'],
    tags: [],
    attributes: [],
  };
}

function categoryTitle(key) {
  return ({ fantasy: '幻想', mystery: '悬疑', history: '历史', urban: '都市', scifi: '科幻', romance: '言情' })[key] ?? '未知';
}

function requireContext() {
  if (context === undefined) throw new Error('Plugin is not activated.');
  return context;
}
