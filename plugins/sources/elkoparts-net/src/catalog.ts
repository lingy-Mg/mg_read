/**
 * Source-local catalog pagination. Owns a bounded in-memory metadata cache for one activation.
 * IO stays in the injected public HTTP reader. Deferred groups load only their real directory pages;
 * chapter IDs remain source-owned and legacy responses fail explicitly instead of truncating 5000 items.
 */
import type { ChaptersRequest, ChaptersResult, ChapterSummary } from './mgread-api.js';

type ParsedChapter = Omit<ChapterSummary, 'order'>;
type Catalog = { firstHtml: string; pages: readonly URL[]; expires: number };
export class ElkopartsCatalog {
  readonly #cache = new Map<string, Promise<Catalog>>();
  constructor(
    private readonly read: (url: URL) => Promise<string>,
    private readonly pages: (html: string, url: URL) => URL[],
    private readonly parse: (html: string, url: URL, id: string) => ParsedChapter[],
  ) {}

  async load(request: ChaptersRequest, firstUrl: URL): Promise<ChaptersResult> {
    if (request.refresh) this.#cache.delete(request.id);
    let pending = this.#cache.get(request.id);
    if (!pending) {
      pending = this.read(firstUrl).then(firstHtml => {
        const pages = this.pages(firstHtml, firstUrl);
        if (pages.length > 1024) throw new Error('Catalog exceeds the supported page bound.');
        return { firstHtml, pages, expires: Date.now() + 15 * 60_000 };
      }).catch(error => { if (this.#cache.get(request.id) === pending) this.#cache.delete(request.id); throw error; });
      this.#cache.set(request.id, pending);
      while (this.#cache.size > 4) this.#cache.delete(this.#cache.keys().next().value!);
    }
    const catalog = await pending;
    if (catalog.expires < Date.now()) { this.#cache.delete(request.id); return this.load(request, firstUrl); }
    const width = Math.max(1, Math.ceil(catalog.pages.length / 128));
    const starts = Array.from({ length: Math.ceil(catalog.pages.length / width) }, (_, index) => index * width);
    const groupId = (start: number) => `${request.id}:catalog:${Buffer.from(catalog.pages[start]!.pathname).toString('base64url')}`;
    const read = async (start: number, count: number) => {
      const pages = catalog.pages.slice(start, start + count);
      const chunks = new Array<ParsedChapter[]>(pages.length);
      let next = 0;
      const worker = async () => { while (next < pages.length) {
        const index = next++, url = pages[index]!;
        const html = start + index === 0 ? catalog.firstHtml : await this.read(url);
        chunks[index] = this.parse(html, url, request.id);
      } };
      await Promise.all(Array.from({ length: Math.min(8, pages.length) }, worker));
      const seen = new Set<string>();
      const items = chunks.flat().filter(item => { if (seen.has(item.id)) return false; seen.add(item.id); return true; }).map((item, order) => ({ ...item, order }));
      if (items.length > 5000) throw new Error('Catalog requires deferred chapter groups.');
      return items;
    };
    if (request.supportsDeferredGroups !== true && request.groupId === undefined) return { items: await read(0, catalog.pages.length) };
    const start = request.groupId === undefined ? 0 : starts.find(value => groupId(value) === request.groupId);
    if (start === undefined) throw new Error('Requested catalog group is unavailable.');
    const items = await read(start, width);
    const groups = starts.map((value, order) => ({
      id: groupId(value), title: `目录第${value + 1}${width > 1 ? `–${Math.min(value + width, catalog.pages.length)}` : ''}页`, order,
      episodes: value === start ? items : [], ...(value === start ? {} : { deferred: true }),
    }));
    return { items, groups };
  }
}
