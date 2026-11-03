/**
 * Anime-library routes and filter rows verified in the public /w/ pages.
 * The site owns option availability and combined links; targets encode a
 * validated filter state, never an arbitrary URL. Pagination is /page/N.
 */
type State = Record<string, string> & { type: string };
const fields = ['area', 'by', 'class', 'letter', 'year'] as const;
const labels = new Map([['类型', 'type'], ['剧情', 'class'], ['地区', 'area'], ['年份', 'year'], ['字母', 'letter'], ['排序', 'by']]);

export function libraryState(target: string): State {
  if (target === 'category:library') return { type: '1' };
  if (!/^library:[A-Za-z0-9_-]{1,1500}$/u.test(target)) throw new Error('Library target is invalid.');
  let value: unknown;
  try { value = JSON.parse(Buffer.from(target.slice(8), 'base64url').toString('utf8')); }
  catch { throw new Error('Library target is invalid.'); }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error('Library target is invalid.');
  const state = value as State;
  if (typeof state.type !== 'string' || !/^\d{1,3}$/u.test(state.type) || Object.keys(state).some((key) => key !== 'type' && !fields.includes(key as typeof fields[number]))) {
    throw new Error('Library target is invalid.');
  }
  for (const field of fields) {
    const entry = state[field];
    if (entry !== undefined && (typeof entry !== 'string' || !/^[\p{L}\p{N} -]{1,40}$/u.test(entry))) throw new Error('Library filter is invalid.');
  }
  return state;
}

export function libraryRoute(state: State, page = 1): string {
  const suffix = fields.filter((field) => state[field] !== undefined).map((field) => `/${field}/${encodeURIComponent(state[field]!)}`).join('');
  return `/w/${state.type}${suffix}${page > 1 ? `/page/${page}` : ''}.html`;
}

export function libraryHasNext(html: string, state: State, page: number): boolean {
  for (const anchor of html.matchAll(/<a\b([^>]*)>/giu)) {
    const href = attribute(anchor[1]!, 'href');
    if (href === null) continue;
    const match = /\/page\/(\d+)\.html$/u.exec(href);
    if (Number(match?.[1]) !== page + 1) continue;
    const next = targetFromRoute(href.replace(/\/page\/\d+\.html$/u, '.html'));
    if (next !== null && libraryRoute(next.state) === libraryRoute(state)) return true;
  }
  return false;
}

function targetFromRoute(href: string): { target: string; state: State } | null {
  const match = /^\/w\/(\d{1,3})((?:\/(?:area|by|class|letter|year)\/[^/]+)*)\.html$/u.exec(href);
  if (match === null) return null;
  const state: State = { type: match[1]! };
  const parts = match[2]!.split('/').slice(1);
  for (let i = 0; i < parts.length; i += 2) {
    try { state[parts[i]!] = decodeURIComponent(parts[i + 1]!); } catch { return null; }
  }
  const ordered: State = { type: state.type };
  for (const field of fields) if (state[field] !== undefined) ordered[field] = state[field]!;
  const target = `library:${Buffer.from(JSON.stringify(ordered)).toString('base64url')}`;
  libraryState(target);
  return { target, state: ordered };
}

export function libraryFilters(html: string) {
  const groups = [];
  const rows = /<div\b[^>]*class=["'][^"']*\bmodule-item-title\b[^"']*["'][^>]*>([\s\S]*?)<\/div>\s*<div\b[^>]*class=["'][^"']*\bmodule-item-box\b[^"']*["'][^>]*>([\s\S]*?)<\/div>/giu;
  for (const row of html.matchAll(rows)) {
    const label = plain(row[1]!);
    const field = labels.get(label);
    if (field === undefined) continue;
    const tabs = [];
    let selectedTabId: string | null = null;
    const seen = new Set<string>();
    for (const anchor of row[2]!.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/giu)) {
      const href = attribute(anchor[1]!, 'href');
      const title = plain(anchor[2]!);
      const option = href === null ? null : targetFromRoute(href);
      if (option === null || title === '') continue;
      const id = `${field}:${Buffer.from(option.state[field] ?? 'all').toString('base64url')}`;
      if (seen.has(id)) continue;
      seen.add(id);
      tabs.push({ id, label: title, target: option.target });
      if ((attribute(anchor[1]!, 'class') ?? '').split(/\s+/u).includes('active')) selectedTabId = id;
    }
    if (tabs.length > 0) groups.push({
      id: field, label, selectedOptionId: selectedTabId, options: tabs,
    });
  }
  return groups.length === 0 ? [] : [{ type: 'filters', id: 'library-filters', resetTarget: 'category:library', groups }];
}

function attribute(html: string, name: string): string | null {
  return new RegExp(`\\b${name}\\s*=\\s*["']([^"']*)["']`, 'iu').exec(html)?.[1]?.replaceAll('&amp;', '&') ?? null;
}

function plain(html: string): string {
  return html.replace(/<[^>]*>/gu, '').replaceAll('&nbsp;', ' ').replaceAll('&amp;', '&').trim();
}
