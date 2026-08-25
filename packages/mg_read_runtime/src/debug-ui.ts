/**
 * Runtime Debug inspector browser assets.
 *
 * Responsibilities:
 * - keep the Debug page shell, visual tokens and browser-side components out of the HTTP router;
 * - render safe Runtime projections, recursive discovery nodes, transient logs and book detail overlays.
 *
 * Boundaries:
 * - uses no CDN or framework runtime so Android/offline Debug sessions stay usable;
 * - never receives raw plugin responses, credentials or Runtime resource tokens.
 *
 * TODO:
 * - None.
 */

export const debugInspectorHtml = `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>MgRead Runtime Debug Inspector</title><link rel="stylesheet" href="/__debug/app.css"></head>
<body><main class="shell"><header class="hero"><div><p class="eyebrow">NODE RUNTIME · DEBUG ONLY</p><h1>MgRead Runtime Debug Inspector</h1><p class="sub">搜索、发现、封面代理与图片解码的同一条 Runtime 调用链。</p></div><p class="risk">局域网调试已开启且无认证。仅在受信任网络中短时使用，完成后请关闭 Flutter 中的调试开关。</p></header>
<section class="panel"><div class="panel-head"><h2>Runtime 状态</h2><span class="hint" id="status-time">加载中…</span></div><div class="status-grid" id="status-grid"></div></section>
<section class="panel"><div class="panel-head"><div><h2>实时简单日志</h2><div class="hint">仅保存在当前 Debug listener 的内存中，关闭后立即清空。</div></div><span class="hint" id="logs-time">等待日志…</span></div><div id="logs-view" class="log-view"><div class="empty">暂无日志。</div></div></section>
<section class="panel"><div class="panel-head"><div><h2>搜索调试</h2><div class="hint">点击书籍可查看完整安全字段与封面探测结果。</div></div></div><div class="form"><label>书源<select id="search-plugin"></select></label><label>关键词<input id="search-q" placeholder="例如：诡秘之主"></label><label>pageSize<input id="search-size" type="number" value="20" min="1" max="50"></label><button id="search" type="button">搜索</button></div><div id="search-view" class="empty">选择书源并执行搜索。</div><details><summary>安全响应摘要</summary><pre id="search-raw">--</pre></details></section>
<section class="panel"><div class="panel-head"><div><h2>发现调试</h2><div class="hint">点击分类继续加载；点击任意书籍查看该书籍数据，而非外层列表包装。</div></div></div><div class="form discover-form"><label>书源<select id="discover-plugin"></select></label><label>target<input id="discover-target" placeholder="首页可留空"></label><label>collectionId<input id="discover-collection" placeholder="分类 collection"></label><label>cursor<input id="discover-cursor" placeholder="续页 cursor"></label><label>pageSize<input id="discover-size" type="number" value="20" min="1" max="50"></label><button id="discover" type="button">加载发现</button></div><div id="discover-view" class="empty">加载首页发现内容，递归树会显示在这里。</div><details><summary>安全响应摘要</summary><pre id="discover-raw">--</pre></details></section></main>
<dialog id="detail-dialog"><header><strong id="detail-title">详情</strong><button id="detail-close" class="secondary" type="button">关闭</button></header><div id="detail-body"></div></dialog>
<script src="/__debug/app.js"></script></body></html>`;

export const debugInspectorCss = `
:root{color:#18233b;background:#f3f6fb;font:14px Inter,system-ui,sans-serif}*{box-sizing:border-box}body{margin:0}.shell{max-width:1320px;margin:auto;padding:28px 20px 64px}.hero{display:flex;align-items:flex-start;justify-content:space-between;gap:20px;margin:8px 0 22px}.eyebrow{margin:0;color:#2563eb;font-weight:800;letter-spacing:.08em;font-size:11px}.hero h1{font-size:28px;margin:5px 0 4px}.sub{color:#64748b;margin:0}.risk{max-width:390px;margin:0;padding:12px 14px;border:1px solid #fed7aa;border-radius:12px;background:#fff7ed;color:#9a3412;line-height:1.5}.panel{background:#fff;border:1px solid #dce4f0;border-radius:16px;padding:18px;margin:16px 0;box-shadow:0 8px 24px rgba(15,23,42,.035)}.panel-head{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:14px}.panel h2{font-size:18px;margin:0}.hint,.meta{color:#64748b;font-size:12px;line-height:1.55;overflow-wrap:anywhere}.status-grid,.book-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px}.stat{background:#f8fafc;border:1px solid #e5eaf2;border-radius:11px;padding:12px}.stat b{display:block;margin-top:5px;word-break:break-word}.log-view{max-height:320px;overflow:auto;border-radius:10px;background:#0f172a;padding:8px}.log-row{display:grid;grid-template-columns:88px 58px 120px 1fr;gap:8px;padding:5px 7px;border-bottom:1px solid #1e293b;color:#dbeafe;font:12px ui-monospace,monospace}.log-row:last-child{border-bottom:0}.log-level{font-weight:800;text-transform:uppercase}.log-level.error{color:#fca5a5}.log-level.warn{color:#fde68a}.form{display:grid;grid-template-columns:1.5fr 1.5fr .7fr auto;gap:10px;align-items:end}.discover-form{grid-template-columns:1.3fr 1fr 1fr 1fr .55fr auto}label{display:grid;gap:5px;color:#475569;font-size:12px;font-weight:700}input,select,button{font:inherit;border-radius:9px;padding:10px}input,select{border:1px solid #cbd5e1;background:white;color:#172033;min-width:0}button{border:0;background:#2563eb;color:white;font-weight:750;cursor:pointer}button:hover{background:#1d4ed8}button.secondary{background:#eef2ff;color:#3730a3;border:1px solid #c7d2fe}.summary{margin:14px 0 4px;color:#475569}.book{display:grid;grid-template-columns:92px 1fr;gap:12px;border:1px solid #e0e7ef;border-radius:13px;padding:11px;background:#fff;cursor:pointer}.book:focus,.tree-node:focus{outline:3px solid #bfdbfe;outline-offset:2px}.cover-box{display:grid;place-items:center;min-height:126px;border-radius:9px;background:#edf2f7;overflow:hidden;color:#94a3b8}.cover-box img{width:100%;height:126px;object-fit:cover}.book h3{font-size:15px;margin:0 0 4px}.chip{display:inline-block;border-radius:20px;padding:2px 8px;margin:6px 5px 4px 0;background:#e0e7ff;color:#3730a3;font-size:11px;font-weight:700}.probe{margin-top:7px;padding:7px 8px;background:#f8fafc;border-radius:7px;color:#475569;font-size:11px}.tree,.node-children{display:grid;gap:8px}.tree-node{border-left:3px solid #bfdbfe;background:#f8fafc;border-radius:0 10px 10px 0;padding:10px 12px;cursor:pointer}.node-head{display:flex;gap:8px;align-items:center;flex-wrap:wrap}.kind{font-size:11px;font-weight:800;color:#1d4ed8;text-transform:uppercase}.node-title{font-weight:750}.inline-actions,.detail-actions{display:flex;gap:6px;flex-wrap:wrap;margin-top:8px}.inline-actions button{font-size:12px;padding:6px 9px}.chapter-list{display:grid;gap:6px;max-height:42vh;overflow:auto;margin-top:12px}.chapter{display:flex;gap:8px;align-items:center;text-align:left;background:#f8fafc;color:#1e293b;border:1px solid #dbe4ee}.chapter span{color:#64748b;font-size:12px}.empty{padding:22px;text-align:center;color:#64748b;border:1px dashed #cbd5e1;border-radius:10px}details{margin-top:14px}summary{cursor:pointer;color:#475569;font-weight:700}pre{max-height:300px;overflow:auto;margin:8px 0 0;padding:12px;border-radius:10px;background:#0f172a;color:#dbeafe;font:12px ui-monospace,monospace;white-space:pre-wrap;overflow-wrap:anywhere}.error{padding:10px;border-radius:9px;background:#fef2f2;color:#b91c1c}.loading{color:#2563eb}dialog{width:min(960px,calc(100vw - 32px));max-height:86vh;border:0;border-radius:16px;padding:0;box-shadow:0 24px 70px rgba(15,23,42,.35)}dialog header{display:flex;justify-content:space-between;gap:12px;align-items:center;padding:16px 18px;border-bottom:1px solid #e2e8f0}#detail-body{padding:16px;overflow:auto;max-height:72vh}#detail-body pre{max-height:52vh}@media(max-width:780px){.hero{display:block}.risk{margin-top:12px}.form,.discover-form{grid-template-columns:1fr 1fr}.form button,.discover-form button{grid-column:span 2}.book-grid{grid-template-columns:1fr}.log-row{grid-template-columns:72px 50px 1fr}.log-row .log-source{display:none}}
`;

export const debugInspectorScript = String.raw`
(() => {
  const by = (id) => document.getElementById(id);
  const state = { defaultPlugin: 'org.mgread.shudugu', nextLogSequence: 0 };
  const text = (value) => value === null || value === undefined ? '--' : String(value);
  const escape = (value) => text(value).replace(/[&<>]/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[char]));
  const api = async (path) => { const response = await fetch(path); const body = await response.json(); if (!response.ok) throw new Error(body.code || String(response.status)); return body; };
  const showDialog = (title, children) => { by('detail-title').textContent = title || '详情'; by('detail-body').replaceChildren(...children); if (!by('detail-dialog').open) by('detail-dialog').showModal(); };
  const jsonView = (value) => { const pre = document.createElement('pre'); pre.textContent = JSON.stringify(value, null, 2); return pre; };
  const action = (label, callback) => { const button = document.createElement('button'); button.className = 'secondary'; button.type = 'button'; button.textContent = label; button.onclick = callback; return button; };
  const clickable = (element, action) => { element.tabIndex = 0; element.onclick = (event) => { event.stopPropagation(); action(); }; element.onkeydown = (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); event.stopPropagation(); action(); } }; };
  const error = (host, value) => { host.className = 'error'; host.textContent = '请求失败：' + (value.message || 'unknown_error'); };
  const raw = (id, value) => { by(id).textContent = JSON.stringify(value, null, 2); };

  async function openBook(pluginId, summary) {
    const title = summary.title || summary.id || '--';
    showDialog('书籍详情 · ' + title, [document.createTextNode('正在通过 Runtime 加载详情…')]);
    try {
      const payload = await api('/__debug/api/detail?' + new URLSearchParams({ pluginId, id: summary.id }));
      const book = payload.result; const visual = document.createElement('div'); visual.className = 'book';
      const art = cover(book.cover); const info = document.createElement('div'); info.innerHTML = '<h3>' + escape(book.title) + '</h3><div class="meta">作者：' + escape(book.author) + '<br>章节：' + escape(book.chapterCount) + ' · 状态：' + escape(book.status) + '<br>' + escape(book.description) + '</div>'; info.append(art.probe); visual.append(art.box, info);
      const actions = document.createElement('div'); actions.className = 'detail-actions'; actions.append(action('加载完整目录', () => void openChapters(pluginId, book)), action('查看安全原始数据', () => showDialog('详情安全原始数据 · ' + title, [jsonView(book)])));
      showDialog('书籍详情 · ' + title, [visual, actions, jsonView(book)]);
    } catch (cause) { showDialog('书籍详情 · ' + title, [document.createTextNode('详情加载失败：' + (cause.message || 'unknown_error'))]); }
  }

  async function openChapters(pluginId, book) {
    showDialog('目录 · ' + text(book.title), [document.createTextNode('正在通过 Runtime 加载完整目录…')]);
    try {
      const payload = await api('/__debug/api/chapters?' + new URLSearchParams({ pluginId, id: book.id })); const chapters = payload.result && Array.isArray(payload.result.items) ? payload.result.items : [];
      const actions = document.createElement('div'); actions.className = 'detail-actions'; actions.append(action('返回详情', () => void openBook(pluginId, book)), action('查看目录安全原始数据', () => showDialog('目录安全原始数据 · ' + text(book.title), [jsonView(payload.result)])));
      const list = document.createElement('div'); list.className = 'chapter-list'; chapters.forEach((chapter) => { const button = document.createElement('button'); button.className = 'chapter'; button.innerHTML = '<b>' + escape(chapter.order) + '. ' + escape(chapter.title) + '</b><span>' + escape(chapter.volumeTitle) + '</span>'; button.onclick = () => void openContent(pluginId, book, chapter); list.append(button); });
      showDialog('目录 · ' + text(book.title) + '（' + chapters.length + '章）', [actions, list]);
    } catch (cause) { showDialog('目录 · ' + text(book.title), [document.createTextNode('目录加载失败：' + (cause.message || 'unknown_error'))]); }
  }

  async function openContent(pluginId, book, chapter) {
    showDialog('正文 · ' + text(chapter.title), [document.createTextNode('正在通过 Runtime 加载正文…')]);
    try {
      const payload = await api('/__debug/api/content?' + new URLSearchParams({ pluginId, id: book.id, chapterId: chapter.id })); const content = payload.result;
      const actions = document.createElement('div'); actions.className = 'detail-actions'; actions.append(action('返回目录', () => void openChapters(pluginId, book)), action('查看正文安全原始数据', () => showDialog('正文安全原始数据 · ' + text(chapter.title), [jsonView(content)])));
      const body = document.createElement('pre'); body.textContent = content.text || '当前内容不是小说正文，或书源未返回文本。';
      showDialog('正文 · ' + text(content.title || chapter.title), [actions, body]);
    } catch (cause) { showDialog('正文 · ' + text(chapter.title), [document.createTextNode('正文加载失败：' + (cause.message || 'unknown_error'))]); }
  }

  function cover(value) {
    const box = document.createElement('div'); box.className = 'cover-box';
    const probe = document.createElement('div'); probe.className = 'probe';
    if (!value) { box.textContent = '无封面'; probe.textContent = '未提供 coverUrl'; return { box, probe }; }
    box.textContent = '等待探测'; probe.textContent = value.type + ' · ' + text(value.displayUrl);
    if (value.probeId) void probeCover(value.probeId, box, probe);
    return { box, probe };
  }

  async function probeCover(probeId, box, host) {
    try {
      host.textContent = '封面探测中…';
      const response = await fetch('/__debug/api/resource-probe?probeId=' + encodeURIComponent(probeId));
      const mime = response.headers.get('content-type') || '--'; const declared = response.headers.get('content-length') || '--'; const blob = await response.blob();
      let decoded = '未解码';
      if (response.ok && mime.startsWith('image/')) { const url = URL.createObjectURL(blob); const image = new Image(); image.src = url; try { await image.decode(); decoded = '可解码'; box.replaceChildren(image); } catch { decoded = '解码失败'; } finally { if (decoded !== '可解码') URL.revokeObjectURL(url); } } else if (response.ok) decoded = '非图片 MIME';
      host.textContent = 'HTTP ' + response.status + ' · ' + mime + ' · 声明 ' + declared + ' · 实际 ' + blob.size + ' bytes · ' + decoded;
    } catch (cause) { host.textContent = '封面请求失败：' + (cause.message || 'network_error'); }
  }

  function createBook(pluginId, item) {
    const card = document.createElement('article'); card.className = 'book';
    clickable(card, () => void openBook(pluginId, item));
    const art = cover(item.cover); const content = document.createElement('div');
    content.innerHTML = '<h3>' + escape(item.title) + '</h3><div class="meta">作者：' + escape(item.author) + '<br>remote ID：' + escape(item.id) + '</div><span class="chip">' + escape(item.cover ? item.cover.type : '无 coverUrl') + '</span>';
    content.append(art.probe); card.append(art.box, content); return card;
  }

  function showBooks(host, pluginId, payload) {
    host.className = ''; host.replaceChildren(); const items = payload.result && Array.isArray(payload.result.items) ? payload.result.items : [];
    const summary = document.createElement('p'); summary.className = 'summary'; summary.textContent = '耗时 ' + payload.elapsedMs + ' ms · ' + items.length + ' 条结果';
    const grid = document.createElement('div'); grid.className = 'book-grid'; if (!items.length) grid.innerHTML = '<div class="empty">没有返回搜索结果。</div>'; items.forEach((item) => grid.append(createBook(pluginId, item))); host.append(summary, grid);
  }

  function createDiscoverNode(pluginId, value, depth) {
    if (Array.isArray(value)) { const group = document.createElement('div'); group.className = 'node-children'; value.forEach((entry) => group.append(createDiscoverNode(pluginId, entry, depth))); return group; }
    const node = document.createElement('article'); node.className = 'tree-node'; node.style.marginLeft = (depth * 14) + 'px'; if (!value || typeof value !== 'object') { node.textContent = '--'; return node; }
    const embedded = value.content && typeof value.content === 'object' && !Array.isArray(value.content) ? value.content : null; const display = embedded || value;
    const kind = value.kind || value.type || value.layout || 'content item'; const title = value.title || value.text || value.label || display.title || value.name || value.id || display.id || '未命名节点';
    clickable(node, () => display.contentKind && display.id ? void openBook(pluginId, display) : showDialog(kind + ' · ' + title, [jsonView(display)]));
    node.innerHTML = '<div class="node-head"><span class="kind">' + escape(kind) + '</span><span class="node-title">' + escape(title) + '</span></div>';
    const fields = ['id','author','contentKind','status','access','language','wordCount','chapterCount','target','collectionId','cursor','nextCursor','totalCount','count','rank','recommendation','publishedAt','updatedAt','description','value'];
    const facts = fields.map((key) => { const field = display[key] ?? value[key]; return field === undefined || field === null ? null : key + '：' + text(field); }).filter(Boolean); if (facts.length) { const meta = document.createElement('div'); meta.className = 'meta'; meta.textContent = facts.join(' · '); node.append(meta); }
    const art = cover(display.cover || value.cover); if (display.cover || value.cover) { const row = document.createElement('div'); row.className = 'book'; row.style.marginTop = '8px'; row.append(art.box, art.probe); node.append(row); }
    const target = typeof value.target === 'string' ? value.target : undefined; const collectionId = typeof value.collectionId === 'string' ? value.collectionId : undefined; const cursor = typeof value.nextCursor === 'string' ? value.nextCursor : typeof value.cursor === 'string' ? value.cursor : undefined;
    if (target !== undefined || collectionId !== undefined || cursor !== undefined) { const action = document.createElement('div'); action.className = 'inline-actions'; const button = document.createElement('button'); button.className = 'secondary'; button.textContent = target ? '加载分类' : '继续加载'; button.onclick = (event) => { event.stopPropagation(); if (target !== undefined) by('discover-target').value = target; if (collectionId !== undefined) by('discover-collection').value = collectionId; if (cursor !== undefined) by('discover-cursor').value = cursor; by('discover').click(); }; action.append(button); node.append(action); }
    const keys = ['document','components','children','items','tabs','categories','metric','continuation']; if (!embedded) keys.splice(5, 0, 'content'); keys.filter((key) => value[key] !== undefined && value[key] !== null).forEach((key) => node.append(createDiscoverNode(pluginId, value[key], depth + 1)));
    return node;
  }

  async function loadStatus() { try { const status = await api('/__debug/api/status'); const grid = by('status-grid'); const entries = [['状态', status.ok ? 'ready' : status.status], ['平台', status.platform], ['Runtime', status.runtimeVersion], ['Node', status.nodeVersion], ['插件数', Array.isArray(status.plugins) ? status.plugins.length : '--'], ['启动时间', status.startedAt]]; grid.replaceChildren(...entries.map(([label, value]) => { const card = document.createElement('div'); card.className = 'stat'; card.innerHTML = '<span class="hint">' + escape(label) + '</span><b>' + escape(value) + '</b>'; return card; })); by('status-time').textContent = '已刷新 ' + new Date().toLocaleTimeString(); } catch (cause) { by('status-grid').textContent = '状态读取失败：' + cause.message; } }
  async function loadLogs() { try { let droppedCount = 0; for (let page = 0; page < 5; page += 1) { const payload = await api('/__debug/api/logs?after=' + state.nextLogSequence + '&limit=200'); const items = Array.isArray(payload.items) ? payload.items : []; const host = by('logs-view'); if (items.length) { if (state.nextLogSequence === 0) host.replaceChildren(); for (const item of items) { const row = document.createElement('div'); row.className = 'log-row'; const time = new Date(item.timestamp).toLocaleTimeString(); row.innerHTML = '<span>' + escape(time) + '</span><span class="log-level ' + escape(item.level) + '">' + escape(item.level) + '</span><span class="log-source">' + escape(item.pluginId || item.source) + '</span><span>' + escape(item.message) + '</span>'; host.append(row); } host.scrollTop = host.scrollHeight; } state.nextLogSequence = Number(payload.nextSequence) || state.nextLogSequence; droppedCount = Number(payload.droppedCount) || 0; if (items.length < 200) break; } by('logs-time').textContent = droppedCount > 0 ? '已刷新；缓冲区已淘汰 ' + droppedCount + ' 条旧日志' : '已刷新 ' + new Date().toLocaleTimeString(); } catch (cause) { by('logs-time').textContent = '日志读取失败：' + cause.message; } }
  async function loadPlugins() { try { const data = await api('/__debug/api/plugins'); const rawPlugins = Array.isArray(data.plugins) ? data.plugins : []; const ids = [...new Set([state.defaultPlugin, ...rawPlugins.map((plugin) => plugin.id).filter((id) => typeof id === 'string')])]; ['search-plugin','discover-plugin'].forEach((id) => { const select = by(id); const previous = select.value || state.defaultPlugin; select.replaceChildren(...ids.map((value) => new Option(value, value))); select.value = ids.includes(previous) ? previous : ids[0]; }); } catch {} }
  by('detail-close').onclick = () => by('detail-dialog').close(); by('detail-dialog').onclick = (event) => { if (event.target === by('detail-dialog')) by('detail-dialog').close(); };
  by('search').onclick = async () => { const host = by('search-view'); const pluginId = by('search-plugin').value; host.className = 'loading'; host.textContent = '正在通过 Runtime 搜索…'; try { const params = new URLSearchParams({ pluginId, q: by('search-q').value, pageSize: by('search-size').value }); const result = await api('/__debug/api/search?' + params); raw('search-raw', result); showBooks(host, pluginId, result); } catch (cause) { error(host, cause); } };
  by('discover').onclick = async () => { const host = by('discover-view'); const pluginId = by('discover-plugin').value; host.className = 'loading'; host.textContent = '正在通过 Runtime 加载发现…'; try { const params = new URLSearchParams({ pluginId, target: by('discover-target').value, collectionId: by('discover-collection').value, cursor: by('discover-cursor').value, pageSize: by('discover-size').value }); const result = await api('/__debug/api/discover?' + params); raw('discover-raw', result); host.className = 'tree'; host.replaceChildren(createDiscoverNode(pluginId, result.result, 0)); } catch (cause) { error(host, cause); } };
  void loadStatus(); void loadPlugins(); void loadLogs(); setInterval(loadLogs, 1_000);
})();
`;
