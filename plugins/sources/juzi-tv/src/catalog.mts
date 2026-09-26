/** Whole-line catalogs and bounded, session-only upstream response cache.
 * Owns TTL/single-flight; activation and refresh fence stale in-flight writes.
 * Contains metadata only. No playback URL is resolved or cached here.
 */
import { createHash } from 'node:crypto';
import type { PluginChaptersRequest } from '@mgread/source-api';
type Json = Record<string, unknown>;
const cache = new Map<string, { value: Json; expires: number; bytes: number }>();
const pending = new Map<string, Promise<Json>>();
let generation = 0;
export function clearCatalogCache() { generation++; cache.clear(); pending.clear(); }
export async function catalogData(id: string, fetch: () => Promise<Json>, refresh = false): Promise<Json> {
  if (refresh) clearCatalogCache();
  const hit = cache.get(id);
  if (hit && hit.expires > Date.now()) { cache.delete(id); cache.set(id, hit); return hit.value; }
  cache.delete(id);
  const running = pending.get(id);
  if (running) return running;
  const epoch = generation;
  const task = fetch().then(value => {
    const bytes = Buffer.byteLength(JSON.stringify(value));
    if (generation === epoch && bytes <= 32 * 1024 * 1024) {
      cache.set(id, { value, bytes, expires: Date.now() + 5 * 60_000 });
      while (cache.size > 2 || [...cache.values()].reduce((sum, entry) => sum + entry.bytes, 0) > 32 * 1024 * 1024) {
        cache.delete(cache.keys().next().value!);
      }
    }
    return value;
  }).finally(() => { if (pending.get(id) === task) pending.delete(id); });
  pending.set(id, task);
  return task;
}
const records = (value: unknown): Json[] => Array.isArray(value) ? value.filter((v): v is Json => !!v && typeof v === 'object') : [];
export function chapterCatalog(id: string, data: Json, request: PluginChaptersRequest) {
  const players = records(data.playerList).filter(player => records(player.epList).length > 0);
  const total = players.reduce((sum, player) => sum + records(player.epList).length, 0);
  const large = total > 1000 && players.length > 1;
  const lazy = large && request.supportsDeferredGroups === true;
  const groups = players.map((player, order) => {
    const title = String(player.playerName || `线路 ${order + 1}`);
    // Existing small catalogs retain their public IDs. Large catalogs use a
    // provider identity, or a stable label digest when the API omits one.
    const identity = String(player.playerId ?? player.id ?? title);
    const groupId = large ? `group:${id}:${createHash('sha256').update(identity).digest('hex').slice(0, 24)}` : `group:${id}:${order}`;
    const deferred = lazy && (request.groupId ? groupId !== request.groupId : order !== 0);
    const episodes = deferred ? [] : records(player.epList).filter(episode => /^\d+$/u.test(String(episode.epId))).map((episode, index) => ({
      id: `vod:${id}:${episode.epId}`, title: String(episode.epName || `第 ${index + 1} 集`),
      order: index, url: null, volumeTitle: title, wordCount: null, updatedAt: null, isLocked: false, attributes: [],
    }));
    return { id: groupId, title, order, episodes, ...(deferred ? { deferred: true } : {}) };
  });
  if (request.groupId && !groups.some(group => group.id === request.groupId)) throw new Error('Requested line is unavailable.');
  return { groups, items: groups.flatMap(group => group.episodes) };
}
