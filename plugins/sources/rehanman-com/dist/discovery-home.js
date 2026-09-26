/** Public homepage rails, projected from rendered HTML. No account/history state is read or retained. */
const rails = [{ id: 'today', title: '今日漫画' }, { id: 'popular', title: '热门漫画' }, { id: 'recommended', title: '推荐' }];
export function homeEntries(html) {
    return html.split(/<div\s+class="slider-product"[^>]*>/u).slice(1).flatMap(block => {
        const title = decode(/<h2\b[^>]*>([\s\S]*?)<\/h2>/u.exec(block)?.[1] ?? '');
        const rail = rails.find(value => value.title === title);
        if (!rail)
            return [];
        const seen = new Set();
        const entries = [...block.matchAll(/<a\b([^>]*\bhref="\/webtoon\/(\d+)"[^>]*)>([\s\S]*?)<\/a>/gu)].flatMap(match => {
            const id = match[2];
            const title = decode(/aria-label="([^"]+)"/u.exec(match[1])?.[1] ?? /<h4\b[^>]*>([\s\S]*?)<\/h4>/u.exec(match[3])?.[1] ?? '');
            if (!title || seen.has(id))
                return [];
            seen.add(id);
            const images = [...match[3].matchAll(/\bsrc="([^"]+)"/gu)].map(value => decode(value[1]));
            const thumbnail = images.flatMap(raw => {
                try {
                    const url = new URL(raw, 'https://rehanman.com');
                    const value = url.pathname === '/_next/image' ? url.searchParams.get('url') : url.toString();
                    return value?.startsWith('https://img.rehanman.com/') ? [value] : [];
                }
                catch {
                    return [];
                }
            })[0] ?? null;
            return [{ title, title_normalized: id, thumbnail }];
        });
        return entries.length ? [{ ...rail, entries }] : [];
    });
}
function decode(value) {
    return value.replace(/<[^>]+>/gu, '').replace(/&#(x[0-9a-f]+|\d+);/giu, (_, code) => { const n = code[0]?.toLowerCase() === 'x' ? parseInt(code.slice(1), 16) : Number(code); return n <= 0x10ffff ? String.fromCodePoint(n) : ''; }).replaceAll('&quot;', '"').replaceAll('&#39;', "'").replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&').trim();
}
