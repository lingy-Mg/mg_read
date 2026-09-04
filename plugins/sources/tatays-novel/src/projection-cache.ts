/** In-memory cache for display projections. */
export interface ProjectionCachePolicy {
  readonly capacity: number;
  readonly freshTtlMs: number;
  readonly staleTtlMs: number;
}

interface CacheEntry<T> {
  readonly value: T;
  readonly freshUntil: number;
  readonly staleUntil: number;
}

export class ProjectionCache<T> {
  readonly #entries = new Map<string, CacheEntry<T>>();
  readonly #flights = new Map<string, Promise<T>>();

  constructor(
    private readonly policy: ProjectionCachePolicy,
    private readonly now: () => number = Date.now,
  ) {
    if (!Number.isSafeInteger(policy.capacity) || policy.capacity < 1) throw new Error('Cache capacity is invalid.');
    if (!Number.isFinite(policy.freshTtlMs) || policy.freshTtlMs < 0) throw new Error('Cache fresh TTL is invalid.');
    if (!Number.isFinite(policy.staleTtlMs) || policy.staleTtlMs <= policy.freshTtlMs) throw new Error('Cache stale TTL is invalid.');
  }

  async get(key: string, load: () => Promise<T>): Promise<T> {
    const current = this.now();
    const entry = this.#entries.get(key);
    if (entry !== undefined && current < entry.freshUntil) {
      this.#touch(key, entry);
      return entry.value;
    }
    if (entry !== undefined && current < entry.staleUntil) {
      this.#touch(key, entry);
      void this.#refresh(key, load).catch(() => undefined);
      return entry.value;
    }
    if (entry !== undefined) this.#entries.delete(key);
    return this.#refresh(key, load);
  }

  #refresh(key: string, load: () => Promise<T>): Promise<T> {
    const active = this.#flights.get(key);
    if (active !== undefined) return active;
    const flight = Promise.resolve()
      .then(load)
      .then((value) => {
        this.#store(key, value);
        return value;
      })
      .finally(() => {
        if (this.#flights.get(key) === flight) this.#flights.delete(key);
      });
    this.#flights.set(key, flight);
    return flight;
  }

  #touch(key: string, entry: CacheEntry<T>): void {
    this.#entries.delete(key);
    this.#entries.set(key, entry);
  }

  #store(key: string, value: T): void {
    const current = this.now();
    this.#entries.delete(key);
    this.#entries.set(key, {
      value,
      freshUntil: current + this.policy.freshTtlMs,
      staleUntil: current + this.policy.staleTtlMs,
    });
    while (this.#entries.size > this.policy.capacity) {
      const oldest = this.#entries.keys().next().value as string | undefined;
      if (oldest === undefined) break;
      this.#entries.delete(oldest);
    }
  }
}
