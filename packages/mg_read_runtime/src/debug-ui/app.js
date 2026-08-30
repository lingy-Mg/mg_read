/**
 * Native Web Components application served by the Runtime Debug listener.
 * Dynamic Runtime projections are always rendered with DOM text nodes, while
 * the three workspaces retain a refresh-safe browser-history route.
 */
(() => {
  'use strict';

  const defaultPlugin = 'org.mgread.shudugu';
  const workspaceRoutes = Object.freeze({
    search: '/__debug/search',
    discover: '/__debug/discover',
    logs: '/__debug/logs',
  });
  const text = (value) => value === null || value === undefined || value === '' ? '--' : String(value);
  const element = (tag, className, content) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (content !== undefined) node.textContent = text(content);
    return node;
  };
  const jsonView = (value) => {
    const node = element('pre', 'json-view');
    node.textContent = JSON.stringify(value, null, 2);
    return node;
  };
  const api = async (path) => {
    const response = await fetch(path);
    const body = await response.json();
    if (!response.ok) throw new Error(body.code || String(response.status));
    return body;
  };
  const copyText = async (value) => {
    if (window.isSecureContext && navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(value);
      return;
    }
    const input = element('textarea');
    input.value = value;
    input.setAttribute('readonly', '');
    input.style.position = 'fixed';
    input.style.opacity = '0';
    document.body.append(input);
    let copied = false;
    try {
      input.select();
      copied = document.execCommand('copy');
    } finally {
      input.remove();
    }
    if (!copied) throw new Error('clipboard_unavailable');
  };
  const setBusy = (button, busy, label) => {
    if (!button.dataset.idleLabel) button.dataset.idleLabel = button.textContent || '';
    button.disabled = busy;
    button.textContent = busy ? label : button.dataset.idleLabel;
  };
  const messageState = (kind, title, description) => {
    const host = element('div', 'message-state ' + kind);
    const body = element('div');
    body.append(element('strong', '', title), element('div', '', description));
    host.append(body);
    return host;
  };
  const emptyState = (icon, title, description) => {
    const host = element('div', 'empty-state');
    const body = element('div');
    body.append(element('span', 'state-icon', icon), element('strong', '', title), element('span', '', description));
    host.append(body);
    return host;
  };
  const button = (label, callback, className) => {
    const node = element('button', 'button ' + (className || ''), label);
    node.type = 'button';
    node.addEventListener('click', callback);
    return node;
  };
  const rawDetails = (value, label) => {
    const details = element('details', 'raw-details');
    details.append(element('summary', '', label || '查看 Runtime 投影数据'), jsonView(value));
    return details;
  };
  const dispatchBook = (host, pluginId, item) => host.dispatchEvent(new CustomEvent('mg-open-book', {
    bubbles: true,
    detail: { pluginId, item },
  }));

  async function probeCover(probeId, box, host) {
    try {
      host.textContent = '正在探测封面…';
      const response = await fetch('/__debug/api/resource-probe?probeId=' + encodeURIComponent(probeId));
      const mime = response.headers.get('content-type') || '--';
      const declared = response.headers.get('content-length') || '--';
      const blob = await response.blob();
      let decoded = '未解码';
      if (response.ok && mime.startsWith('image/')) {
        const url = URL.createObjectURL(blob);
        const image = new Image();
        image.alt = '';
        image.src = url;
        try {
          await image.decode();
          decoded = '可解码';
          box.replaceChildren(image);
        } catch {
          decoded = '解码失败';
        } finally {
          URL.revokeObjectURL(url);
        }
      } else if (response.ok) {
        decoded = '非图片 MIME';
      }
      host.textContent = 'HTTP ' + response.status + ' · ' + mime + ' · 声明 ' + declared + ' · 实际 ' + blob.size + ' bytes · ' + decoded;
    } catch (cause) {
      host.textContent = '封面请求失败：' + (cause.message || 'network_error');
    }
  }

  function createCover(value) {
    const box = element('div', 'cover-box', value ? '等待探测' : '无封面');
    const probe = element('div', 'probe', value ? text(value.type) + ' · ' + text(value.displayUrl) : '未提供 coverUrl');
    if (value && value.probeId) void probeCover(value.probeId, box, probe);
    return { box, probe };
  }

  class MgBookCard extends HTMLElement {
    set data(value) {
      this.replaceChildren();
      const control = element('button', 'book-card');
      control.type = 'button';
      control.setAttribute('aria-label', '查看书籍详情：' + text(value.item.title));
      control.addEventListener('click', () => dispatchBook(this, value.pluginId, value.item));
      const art = createCover(value.item.cover);
      const content = element('div', 'book-content');
      content.append(
        element('h3', '', value.item.title),
        element('div', 'book-author', '作者：' + text(value.item.author)),
        element('div', 'book-id', 'ID · ' + text(value.item.id)),
      );
      const chips = element('div', 'chip-row');
      chips.append(element('span', 'chip', value.item.cover ? value.item.cover.type : '无封面'));
      content.append(chips, art.probe);
      control.append(art.box, content);
      this.append(control);
    }
  }

  class MgRuntimeStatus extends HTMLElement {
    connectedCallback() {
      if (this.dataset.ready) return;
      this.dataset.ready = 'true';
      this.replaceChildren();
      const heading = element('div', 'section-heading');
      const copy = element('div');
      copy.append(element('h2', '', '信息面板'), element('p', '', 'Runtime 运行状态与当前调试入口。'));
      const actions = element('div', 'heading-actions');
      actions.append(element('span', 'debug-safety-note', '局域网调试 · 无认证'));
      this.updated = element('span', 'last-updated', '尚未刷新');
      this.refresh = button('↻ 刷新状态', () => void this.load(), 'secondary compact');
      actions.append(this.updated, this.refresh);
      heading.append(copy, actions);
      this.grid = element('div', 'status-grid');
      this.append(heading, this.grid);
      void this.load();
    }

    async load() {
      setBusy(this.refresh, true, '正在刷新…');
      try {
        const status = await api('/__debug/api/status');
        const entries = [
          ['状态', status.ok ? 'Ready' : status.status, true],
          ['平台', status.platform, false],
          ['Runtime', status.runtimeVersion, false],
          ['Node', status.nodeVersion, false],
          ['插件数量', Array.isArray(status.plugins) ? status.plugins.length : '--', false],
          ['启动时间', status.startedAt ? new Date(status.startedAt).toLocaleString() : '--', false],
        ];
        this.grid.replaceChildren(...entries.map(([label, value, primary]) => {
          const card = element('div', 'stat-card' + (primary ? ' primary' : ''));
          card.append(element('span', 'stat-label', label), element('strong', 'stat-value', value));
          card.title = text(value);
          return card;
        }));
        this.updated.textContent = '更新于 ' + new Date().toLocaleTimeString();
      } catch (cause) {
        this.grid.replaceChildren(messageState('error status-error', '状态读取失败', cause.message || 'unknown_error'));
        this.updated.textContent = '刷新失败';
      } finally {
        setBusy(this.refresh, false, '');
      }
    }
  }

  class MgSearchPanel extends HTMLElement {
    connectedCallback() {
      if (this.dataset.ready) return;
      this.dataset.ready = 'true';
      this.innerHTML = [
        '<div class="tool-layout">',
        '<form class="form-grid" novalidate>',
        '<label class="field">数据源<select name="pluginId" aria-label="搜索数据源"></select></label>',
        '<label class="field">关键词<input name="query" autocomplete="off" maxlength="160" placeholder="输入书名或作者，按 Enter 搜索" required></label>',
        '<label class="field">每页数量<input name="pageSize" type="number" value="20" min="1" max="50"></label>',
        '<button class="button" type="submit">开始搜索</button>',
        '</form>',
        '<div class="result-shell"></div>',
        '</div>',
      ].join('');
      this.form = this.querySelector('form');
      this.plugin = this.querySelector('[name="pluginId"]');
      this.query = this.querySelector('[name="query"]');
      this.pageSize = this.querySelector('[name="pageSize"]');
      this.submit = this.querySelector('[type="submit"]');
      this.result = this.querySelector('.result-shell');
      this.result.replaceChildren(emptyState('⌕', '等待搜索', '选择数据源并输入关键词，结果会显示在这里。'));
      this.form.addEventListener('submit', (event) => {
        event.preventDefault();
        void this.search();
      });
      this.query.addEventListener('keydown', (event) => {
        if (event.key !== 'Enter') return;
        event.preventDefault();
        this.form.requestSubmit();
      });
    }

    setPlugins(ids) {
      const previous = this.plugin.value || defaultPlugin;
      this.plugin.replaceChildren(...ids.map((id) => new Option(id, id)));
      this.plugin.value = ids.includes(previous) ? previous : ids[0] || '';
    }

    async search() {
      const query = this.query.value.trim();
      if (!query) {
        this.query.setCustomValidity('请输入搜索关键词');
        this.query.reportValidity();
        this.query.setCustomValidity('');
        return;
      }
      setBusy(this.submit, true, '搜索中…');
      this.result.replaceChildren(messageState('loading', '正在搜索', 'Runtime 正在请求数据源并校验返回结果。'));
      try {
        const params = new URLSearchParams({ pluginId: this.plugin.value, q: query, pageSize: this.pageSize.value });
        const payload = await api('/__debug/api/search?' + params);
        const items = payload.result && Array.isArray(payload.result.items) ? payload.result.items : [];
        const fragment = document.createDocumentFragment();
        const meta = element('div', 'result-meta');
        meta.append(element('strong', '', items.length ? '搜索结果' : '没有匹配结果'), element('span', '', '耗时 ' + text(payload.elapsedMs) + ' ms · ' + items.length + ' 条'));
        fragment.append(meta);
        if (items.length) {
          const grid = element('div', 'book-grid');
          for (const item of items) {
            const card = document.createElement('mg-book-card');
            card.data = { pluginId: this.plugin.value, item };
            grid.append(card);
          }
          fragment.append(grid);
        } else {
          fragment.append(emptyState('∅', '没有返回搜索结果', '可以调整关键词或切换数据源后重试。'));
        }
        fragment.append(rawDetails(payload, '查看搜索投影数据'));
        this.result.replaceChildren(fragment);
      } catch (cause) {
        this.result.replaceChildren(messageState('error', '搜索失败', cause.message || 'unknown_error'));
      } finally {
        setBusy(this.submit, false, '');
      }
    }
  }

  function createDiscoveryNode(owner, pluginId, value, depth) {
    if (Array.isArray(value)) {
      const group = element('div', 'node-children');
      for (const entry of value) group.append(createDiscoveryNode(owner, pluginId, entry, depth));
      return group;
    }
    const node = element('article', 'tree-node');
    node.style.marginLeft = Math.min(depth, 8) * 12 + 'px';
    if (!value || typeof value !== 'object') {
      node.append(element('span', 'node-title', '--'));
      return node;
    }
    const embedded = value.content && typeof value.content === 'object' && !Array.isArray(value.content) ? value.content : null;
    const display = embedded || value;
    const kind = value.kind || value.type || value.layout || 'content item';
    const title = value.title || value.text || value.label || display.title || value.name || value.id || display.id || '未命名节点';
    const head = element('div', 'node-head');
    head.append(element('span', 'node-kind', kind), element('span', 'node-title', title));
    node.append(head);
    if (display.contentKind && display.id) {
      node.classList.add('interactive');
      node.tabIndex = 0;
      node.setAttribute('role', 'button');
      const open = () => dispatchBook(owner, pluginId, display);
      node.addEventListener('click', open);
      node.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          open();
        }
      });
    }
    const fields = ['id','author','contentKind','status','access','language','wordCount','chapterCount','target','collectionId','cursor','nextCursor','totalCount','count','rank','recommendation','publishedAt','updatedAt','description','value'];
    const facts = fields.map((key) => {
      const field = display[key] ?? value[key];
      return field === undefined || field === null ? null : key + '：' + text(field);
    }).filter(Boolean);
    if (facts.length) node.append(element('div', 'node-meta', facts.join(' · ')));
    const coverValue = display.cover || value.cover;
    if (coverValue) {
      const art = createCover(coverValue);
      const row = element('div', 'node-cover');
      row.append(art.box, art.probe);
      node.append(row);
    }
    const target = typeof value.target === 'string' ? value.target : undefined;
    const collectionId = typeof value.collectionId === 'string' ? value.collectionId : undefined;
    const cursor = typeof value.nextCursor === 'string' ? value.nextCursor : typeof value.cursor === 'string' ? value.cursor : undefined;
    if (target !== undefined || collectionId !== undefined || cursor !== undefined) {
      const actions = element('div', 'node-actions');
      actions.append(button(target ? '加载分类' : '继续加载', (event) => {
        event.stopPropagation();
        void owner.load({ target, collectionId, cursor });
      }, 'secondary compact'));
      node.append(actions);
    }
    const keys = ['document','components','children','items','tabs','categories','metric','continuation'];
    if (!embedded) keys.splice(5, 0, 'content');
    for (const key of keys) {
      if (value[key] !== undefined && value[key] !== null) node.append(createDiscoveryNode(owner, pluginId, value[key], depth + 1));
    }
    return node;
  }

  class MgDiscoveryPanel extends HTMLElement {
    connectedCallback() {
      if (this.dataset.ready) return;
      this.dataset.ready = 'true';
      this.innerHTML = [
        '<div class="tool-layout">',
        '<form novalidate>',
        '<div class="form-grid discover">',
        '<label class="field">数据源<select name="pluginId" aria-label="发现数据源"></select></label>',
        '<label class="field">每页数量<input name="pageSize" type="number" value="20" min="1" max="50"></label>',
        '<button class="button" type="submit">加载发现</button>',
        '</div>',
        '<details class="advanced"><summary>高级参数 · target / collectionId / cursor</summary>',
        '<div class="advanced-grid">',
        '<label class="field">target<input name="target" placeholder="首页可留空"></label>',
        '<label class="field">collectionId<input name="collectionId" placeholder="分类 collection"></label>',
        '<label class="field">cursor<input name="cursor" placeholder="续页 cursor"></label>',
        '</div></details>',
        '</form>',
        '<div class="result-shell"></div>',
        '</div>',
      ].join('');
      this.form = this.querySelector('form');
      this.plugin = this.querySelector('[name="pluginId"]');
      this.pageSize = this.querySelector('[name="pageSize"]');
      this.target = this.querySelector('[name="target"]');
      this.collectionId = this.querySelector('[name="collectionId"]');
      this.cursor = this.querySelector('[name="cursor"]');
      this.submit = this.querySelector('[type="submit"]');
      this.result = this.querySelector('.result-shell');
      this.result.replaceChildren(emptyState('◇', '等待加载发现', '默认参数会加载数据源首页，分类与续页可使用高级参数。'));
      this.form.addEventListener('submit', (event) => {
        event.preventDefault();
        void this.load();
      });
    }

    setPlugins(ids) {
      const previous = this.plugin.value || defaultPlugin;
      this.plugin.replaceChildren(...ids.map((id) => new Option(id, id)));
      this.plugin.value = ids.includes(previous) ? previous : ids[0] || '';
    }

    async load(overrides) {
      if (overrides) {
        if (overrides.target !== undefined) this.target.value = overrides.target;
        if (overrides.collectionId !== undefined) this.collectionId.value = overrides.collectionId;
        if (overrides.cursor !== undefined) this.cursor.value = overrides.cursor;
      }
      setBusy(this.submit, true, '加载中…');
      this.result.replaceChildren(messageState('loading', '正在加载发现', 'Runtime 正在请求数据源并构建递归内容树。'));
      try {
        const params = new URLSearchParams({
          pluginId: this.plugin.value,
          target: this.target.value,
          collectionId: this.collectionId.value,
          cursor: this.cursor.value,
          pageSize: this.pageSize.value,
        });
        const payload = await api('/__debug/api/discover?' + params);
        const fragment = document.createDocumentFragment();
        const meta = element('div', 'result-meta');
        meta.append(element('strong', '', '发现内容树'), element('span', '', '耗时 ' + text(payload.elapsedMs) + ' ms'));
        const tree = element('div', 'tree');
        tree.append(createDiscoveryNode(this, this.plugin.value, payload.result, 0));
        fragment.append(meta, tree, rawDetails(payload, '查看发现投影数据'));
        this.result.replaceChildren(fragment);
      } catch (cause) {
        this.result.replaceChildren(messageState('error', '发现加载失败', cause.message || 'unknown_error'));
      } finally {
        setBusy(this.submit, false, '');
      }
    }
  }

  class MgLogViewer extends HTMLElement {
    constructor() {
      super();
      this.entries = [];
      this.nextSequence = 0;
      this.active = false;
      this.userPaused = false;
      this.timer = undefined;
    }

    connectedCallback() {
      if (this.dataset.ready) return;
      this.dataset.ready = 'true';
      this.innerHTML = [
        '<div class="log-toolbar">',
        '<div class="heading-actions"><span class="live-badge paused">已暂停</span><span class="last-updated">等待日志</span></div>',
        '<select class="filter-control" aria-label="日志级别"><option value="all">全部级别</option><option value="error">Error</option><option value="warn">Warn</option><option value="info">Info</option><option value="debug">Debug</option></select>',
        '<input class="filter-control" type="search" aria-label="筛选日志" placeholder="按来源、代码或消息筛选">',
        '<div class="heading-actions"><button class="button secondary compact" data-action="copy" type="button">复制日志</button><button class="button secondary compact" data-action="pause" type="button">继续接收</button><button class="button ghost compact" data-action="clear" type="button">清空当前视图</button></div>',
        '</div>',
        '<div class="log-view"><div class="log-empty">切换到日志工作区后开始接收。</div></div>',
      ].join('');
      this.badge = this.querySelector('.live-badge');
      this.updated = this.querySelector('.last-updated');
      this.view = this.querySelector('.log-view');
      this.level = this.querySelector('select');
      this.filter = this.querySelector('input');
      this.copy = this.querySelector('[data-action="copy"]');
      this.pause = this.querySelector('[data-action="pause"]');
      this.copy.addEventListener('click', () => void this.copyEntries());
      this.querySelector('[data-action="clear"]').addEventListener('click', () => {
        this.entries = [];
        this.renderEntries();
      });
      this.pause.addEventListener('click', () => {
        this.userPaused = !this.userPaused;
        this.syncPolling();
      });
      this.level.addEventListener('change', () => this.renderEntries());
      this.filter.addEventListener('input', () => this.renderEntries());
    }

    disconnectedCallback() { this.stopPolling(); }
    setActive(value) { this.active = value; this.syncPolling(); }

    syncPolling() {
      const running = this.active && !this.userPaused;
      this.badge.classList.toggle('paused', !running);
      this.badge.textContent = running ? '实时接收中' : this.userPaused ? '手动暂停' : '工作区未打开';
      this.pause.textContent = this.userPaused ? '继续接收' : '暂停接收';
      if (running) this.startPolling(); else this.stopPolling();
    }

    startPolling() {
      if (this.timer !== undefined) return;
      void this.load();
      this.timer = window.setInterval(() => void this.load(), 1000);
    }

    stopPolling() {
      if (this.timer === undefined) return;
      window.clearInterval(this.timer);
      this.timer = undefined;
    }

    async load() {
      try {
        let droppedCount = 0;
        let changed = false;
        for (let page = 0; page < 5; page += 1) {
          const payload = await api('/__debug/api/logs?after=' + this.nextSequence + '&limit=200');
          const items = Array.isArray(payload.items) ? payload.items : [];
          if (items.length) {
            this.entries.push(...items);
            if (this.entries.length > 1000) this.entries.splice(0, this.entries.length - 1000);
            changed = true;
          }
          this.nextSequence = Number(payload.nextSequence) || this.nextSequence;
          droppedCount = Number(payload.droppedCount) || 0;
          if (items.length < 200) break;
        }
        if (changed) this.renderEntries();
        this.updated.textContent = droppedCount > 0 ? '已淘汰 ' + droppedCount + ' 条旧日志' : '更新于 ' + new Date().toLocaleTimeString();
      } catch (cause) {
        this.updated.textContent = '日志读取失败：' + (cause.message || 'unknown_error');
      }
    }

    filteredEntries() {
      const query = this.filter.value.trim().toLocaleLowerCase();
      const level = this.level.value;
      return this.entries.filter((entry) => {
        if (level !== 'all' && entry.level !== level) return false;
        if (!query) return true;
        return [entry.pluginId, entry.source, entry.code, entry.message].some((value) => text(value).toLocaleLowerCase().includes(query));
      });
    }

    async copyEntries() {
      const entries = this.filteredEntries();
      const idleLabel = '复制日志';
      if (!entries.length) {
        this.copy.textContent = '暂无可复制日志';
        window.setTimeout(() => { this.copy.textContent = idleLabel; }, 1400);
        return;
      }
      this.copy.disabled = true;
      this.copy.textContent = '复制中…';
      try {
        const content = entries.map((entry) => {
          const source = entry.pluginId || entry.source || '--';
          const code = entry.code ? ' [' + entry.code + ']' : '';
          return entry.timestamp + ' [' + text(entry.level).toUpperCase() + '] [' + source + ']' + code + ' ' + text(entry.message);
        }).join('\n');
        await copyText(content);
        this.copy.textContent = '已复制 ' + entries.length + ' 条';
      } catch {
        this.copy.textContent = '复制失败';
      } finally {
        this.copy.disabled = false;
        window.setTimeout(() => { this.copy.textContent = idleLabel; }, 1400);
      }
    }

    renderEntries() {
      const entries = this.filteredEntries();
      const nearBottom = this.view.scrollHeight - this.view.scrollTop - this.view.clientHeight < 60;
      if (!entries.length) {
        this.view.replaceChildren(element('div', 'log-empty', this.entries.length ? '没有符合筛选条件的日志。' : '暂无日志。'));
        return;
      }
      this.view.replaceChildren(...entries.map((entry) => {
        const row = element('div', 'log-row');
        row.append(
          element('span', 'log-time', new Date(entry.timestamp).toLocaleTimeString()),
          element('span', 'log-level ' + text(entry.level), entry.level),
          element('span', 'log-source', entry.pluginId || entry.source),
          element('span', 'log-message', entry.message),
        );
        return row;
      }));
      if (nearBottom) this.view.scrollTop = this.view.scrollHeight;
    }
  }

  class MgDetailDialog extends HTMLElement {
    connectedCallback() {
      if (this.dataset.ready) return;
      this.dataset.ready = 'true';
      this.innerHTML = [
        '<dialog>',
        '<header class="dialog-head"><div><p class="dialog-kicker">RUNTIME CONTENT FLOW</p><h2 class="dialog-title">内容详情</h2></div><button class="button secondary compact" type="button">关闭</button></header>',
        '<div class="dialog-body"></div>',
        '</dialog>',
      ].join('');
      this.dialog = this.querySelector('dialog');
      this.titleNode = this.querySelector('.dialog-title');
      this.body = this.querySelector('.dialog-body');
      this.querySelector('button').addEventListener('click', () => this.dialog.close());
      this.dialog.addEventListener('click', (event) => { if (event.target === this.dialog) this.dialog.close(); });
    }

    show(title, children) {
      this.titleNode.textContent = title || '内容详情';
      this.body.replaceChildren(...children);
      if (!this.dialog.open) this.dialog.showModal();
      this.body.scrollTop = 0;
    }

    async openBook(pluginId, summary) {
      const title = summary.title || summary.id || '--';
      this.show('书籍详情 · ' + title, [messageState('loading', '正在加载详情', '正在通过 Runtime 获取完整投影字段。')]);
      try {
        const payload = await api('/__debug/api/detail?' + new URLSearchParams({ pluginId, id: summary.id }));
        const book = payload.result;
        const visual = element('div', 'detail-visual');
        const art = createCover(book.cover);
        const info = element('div');
        info.append(
          element('h3', '', book.title),
          element('div', 'book-author', '作者：' + text(book.author)),
          element('div', 'node-meta', '章节：' + text(book.chapterCount) + ' · 状态：' + text(book.status) + ' · 类型：' + text(book.contentKind)),
          element('div', 'detail-description', book.description || '没有提供简介。'),
          art.probe,
        );
        visual.append(art.box, info);
        const actions = element('div', 'dialog-actions');
        actions.append(
          button('加载完整目录', () => void this.openChapters(pluginId, book), ''),
          button('单独查看投影数据', () => this.show('详情投影数据 · ' + title, [button('← 返回详情', () => void this.openBook(pluginId, book), 'secondary compact'), jsonView(book)]), 'secondary'),
        );
        this.show('书籍详情 · ' + title, [visual, actions, rawDetails(book, '展开详情投影数据')]);
      } catch (cause) {
        this.show('书籍详情 · ' + title, [messageState('error', '详情加载失败', cause.message || 'unknown_error')]);
      }
    }

    async openChapters(pluginId, book) {
      this.show('目录 · ' + text(book.title), [messageState('loading', '正在加载完整目录', '章节 ID 会继续作为不透明引用传递。')]);
      try {
        const payload = await api('/__debug/api/chapters?' + new URLSearchParams({ pluginId, id: book.id }));
        const chapters = payload.result && Array.isArray(payload.result.items) ? payload.result.items : [];
        const actions = element('div', 'dialog-actions');
        actions.append(
          button('← 返回详情', () => void this.openBook(pluginId, book), 'secondary'),
          button('查看目录投影数据', () => this.show('目录投影数据 · ' + text(book.title), [button('← 返回目录', () => void this.openChapters(pluginId, book), 'secondary compact'), jsonView(payload.result)]), 'secondary'),
        );
        const list = element('div', 'chapter-list');
        for (const chapter of chapters) {
          const control = element('button', 'chapter-button');
          control.type = 'button';
          control.append(element('span', 'chapter-order', '#' + text(chapter.order)), element('strong', '', chapter.title), element('span', 'chapter-volume', chapter.volumeTitle));
          control.addEventListener('click', () => void this.openContent(pluginId, book, chapter));
          list.append(control);
        }
        if (!chapters.length) list.append(emptyState('∅', '没有返回章节', '数据源目录为空。'));
        this.show('目录 · ' + text(book.title) + '（' + chapters.length + ' 章）', [actions, list]);
      } catch (cause) {
        this.show('目录 · ' + text(book.title), [messageState('error', '目录加载失败', cause.message || 'unknown_error')]);
      }
    }

    async openContent(pluginId, book, chapter) {
      this.show('正文 · ' + text(chapter.title), [messageState('loading', '正在加载正文', '正文仅在主动选择章节后请求。')]);
      try {
        const payload = await api('/__debug/api/content?' + new URLSearchParams({ pluginId, id: book.id, chapterId: chapter.id }));
        const content = payload.result;
        const actions = element('div', 'dialog-actions');
        actions.append(
          button('← 返回目录', () => void this.openChapters(pluginId, book), 'secondary'),
          button('查看正文投影数据', () => this.show('正文投影数据 · ' + text(chapter.title), [button('← 返回正文', () => void this.openContent(pluginId, book, chapter), 'secondary compact'), jsonView(content)]), 'secondary'),
        );
        const body = element('div', 'content-view', content.text || '当前内容不是小说正文，或数据源未返回文本。');
        this.show('正文 · ' + text(content.title || chapter.title), [actions, body]);
      } catch (cause) {
        this.show('正文 · ' + text(chapter.title), [messageState('error', '正文加载失败', cause.message || 'unknown_error')]);
      }
    }
  }

  class MgDebugApp extends HTMLElement {
    connectedCallback() {
      if (this.dataset.ready) return;
      this.dataset.ready = 'true';
      this.innerHTML = [
        '<main class="content-shell">',
        '<mg-runtime-status class="information-panel"></mg-runtime-status>',
        '<section class="workspace">',
        '<header class="workspace-bar"><nav class="tabs" role="tablist" aria-label="调试工作区"><button class="tab" role="tab" aria-selected="true" data-tab="search" type="button">搜索</button><button class="tab" role="tab" aria-selected="false" data-tab="discover" type="button">发现</button><button class="tab" role="tab" aria-selected="false" data-tab="logs" type="button">实时日志</button></nav></header>',
        '<div class="workspace-panel" role="tabpanel" data-panel="search"><mg-search-panel></mg-search-panel></div>',
        '<div class="workspace-panel" role="tabpanel" data-panel="discover" hidden><mg-discovery-panel></mg-discovery-panel></div>',
        '<div class="workspace-panel" role="tabpanel" data-panel="logs" hidden><mg-log-viewer></mg-log-viewer></div>',
        '</section>',
        '</main>',
        '<mg-detail-dialog></mg-detail-dialog>',
        '</div>',
      ].join('');
      this.search = this.querySelector('mg-search-panel');
      this.discovery = this.querySelector('mg-discovery-panel');
      this.logs = this.querySelector('mg-log-viewer');
      this.detail = this.querySelector('mg-detail-dialog');
      for (const tab of this.querySelectorAll('[role="tab"]')) tab.addEventListener('click', () => this.selectTab(tab.dataset.tab, true));
      this.addEventListener('mg-open-book', (event) => void this.detail.openBook(event.detail.pluginId, event.detail.item));
      document.addEventListener('visibilitychange', () => this.syncLogs());
      window.addEventListener('popstate', () => this.selectTab(this.tabFromLocation(), false));
      void this.loadPlugins();
      this.selectTab(this.tabFromLocation(), false);
    }

    tabFromLocation() {
      return Object.entries(workspaceRoutes).find(([, route]) => window.location.pathname === route)?.[0] || 'search';
    }

    selectTab(name, writeHistory) {
      const selected = Object.hasOwn(workspaceRoutes, name) ? name : 'search';
      if (writeHistory && window.location.pathname !== workspaceRoutes[selected]) window.history.pushState({ tab: selected }, '', workspaceRoutes[selected]);
      for (const tab of this.querySelectorAll('[role="tab"]')) tab.setAttribute('aria-selected', String(tab.dataset.tab === selected));
      for (const panel of this.querySelectorAll('[role="tabpanel"]')) panel.hidden = panel.dataset.panel !== selected;
      this.syncLogs();
    }

    syncLogs() {
      const selected = this.querySelector('[role="tab"][aria-selected="true"]');
      this.logs.setActive(document.visibilityState === 'visible' && selected && selected.dataset.tab === 'logs');
    }

    async loadPlugins() {
      try {
        const data = await api('/__debug/api/plugins');
        const raw = Array.isArray(data.plugins) ? data.plugins : [];
        const ids = [...new Set([defaultPlugin, ...raw.map((plugin) => plugin.id).filter((id) => typeof id === 'string')])];
        this.search.setPlugins(ids);
        this.discovery.setPlugins(ids);
      } catch {
        this.search.setPlugins([defaultPlugin]);
        this.discovery.setPlugins([defaultPlugin]);
      }
    }
  }

  customElements.define('mg-book-card', MgBookCard);
  customElements.define('mg-runtime-status', MgRuntimeStatus);
  customElements.define('mg-search-panel', MgSearchPanel);
  customElements.define('mg-discovery-panel', MgDiscoveryPanel);
  customElements.define('mg-log-viewer', MgLogViewer);
  customElements.define('mg-detail-dialog', MgDetailDialog);
  customElements.define('mg-debug-app', MgDebugApp);
})();
