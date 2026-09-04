export class ProjectionCache {
    policy;
    now;
    #entries = new Map();
    #flights = new Map();
    constructor(policy, now = Date.now) {
        this.policy = policy;
        this.now = now;
        if (!Number.isSafeInteger(policy.capacity) || policy.capacity < 1)
            throw new Error('Cache capacity is invalid.');
        if (!Number.isFinite(policy.freshTtlMs) || policy.freshTtlMs < 0)
            throw new Error('Cache fresh TTL is invalid.');
        if (!Number.isFinite(policy.staleTtlMs) || policy.staleTtlMs <= policy.freshTtlMs)
            throw new Error('Cache stale TTL is invalid.');
    }
    async get(key, load) {
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
        if (entry !== undefined)
            this.#entries.delete(key);
        return this.#refresh(key, load);
    }
    #refresh(key, load) {
        const active = this.#flights.get(key);
        if (active !== undefined)
            return active;
        const flight = Promise.resolve()
            .then(load)
            .then((value) => {
            this.#store(key, value);
            return value;
        })
            .finally(() => {
            if (this.#flights.get(key) === flight)
                this.#flights.delete(key);
        });
        this.#flights.set(key, flight);
        return flight;
    }
    #touch(key, entry) {
        this.#entries.delete(key);
        this.#entries.set(key, entry);
    }
    #store(key, value) {
        const current = this.now();
        this.#entries.delete(key);
        this.#entries.set(key, {
            value,
            freshUntil: current + this.policy.freshTtlMs,
            staleUntil: current + this.policy.staleTtlMs,
        });
        while (this.#entries.size > this.policy.capacity) {
            const oldest = this.#entries.keys().next().value;
            if (oldest === undefined)
                break;
            this.#entries.delete(oldest);
        }
    }
}
