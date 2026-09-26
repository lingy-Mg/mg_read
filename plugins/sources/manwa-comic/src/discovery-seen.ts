/** Manwa repeats cards across adjacent API pages. Keep 64 recent numeric identities in a bounded, stateless cursor. */
import { position } from './discovery-page.js';
export function readCursor(cursor: string|null, target: string) {
  const parts = cursor?.split('|') ?? [];
  if (parts.length > 2 || (parts[1] !== undefined && !/^\d{1,18}(?:,\d{1,18}){0,63}$/u.test(parts[1]))) throw new Error('Discovery cursor is invalid.');
  return {...position(parts[0]??null,target),seen:new Set(parts[1]?.split(',')??[])};
}
export function continueAt(target: string, page: number, offset: number, seen: Set<string>) {
  const ids=[...seen].slice(-64);
  return {target,cursor:target+':'+page+':'+offset+(ids.length?'|'+ids.join(','):'')};
}
