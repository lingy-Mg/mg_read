/**
 * 爱丽丝发现详情有界补全器。
 *
 * 职责：按原始顺序并发补全列表投影，并在可选截止时间到达时返回不可变快照。
 * 注意：截止后仍在执行的任务只能填充内部缓存，不能改写已经返回的列表。
 * TODO: - 无。
 */

export interface DetailHydrationOptions<T> {
  readonly maximumConcurrency: number;
  readonly deadlineMs?: number;
  readonly hydrate: (item: T, index: number) => Promise<T>;
  readonly onFailure: (item: T, index: number) => Promise<T> | T;
}

export async function hydrateDetailsInOrder<T>(
  items: readonly T[],
  options: DetailHydrationOptions<T>,
): Promise<readonly T[]> {
  if (!Number.isSafeInteger(options.maximumConcurrency) || options.maximumConcurrency <= 0) {
    throw new Error('Detail hydration concurrency is invalid.');
  }
  if (options.deadlineMs !== undefined && !Number.isSafeInteger(options.deadlineMs)) {
    throw new Error('Detail hydration deadline is invalid.');
  }
  if (items.length === 0) return Object.freeze([]);

  const hydrated = new Array<T | undefined>(items.length);
  let nextIndex = 0;
  const worker = async (): Promise<void> => {
    while (
      nextIndex < items.length &&
      (options.deadlineMs === undefined || Date.now() < options.deadlineMs)
    ) {
      const index = nextIndex;
      nextIndex += 1;
      const item = items[index]!;
      try {
        hydrated[index] = await options.hydrate(item, index);
      } catch {
        try {
          hydrated[index] = await options.onFailure(item, index);
        } catch {
          hydrated[index] = item;
        }
      }
    }
  };
  const completion = Promise.all(
    Array.from(
      { length: Math.min(options.maximumConcurrency, items.length) },
      () => worker(),
    ),
  );

  if (options.deadlineMs === undefined) {
    await completion;
  } else {
    const remainingMs = Math.max(0, options.deadlineMs - Date.now());
    if (remainingMs > 0) {
      let timer: NodeJS.Timeout | undefined;
      const deadline = new Promise<void>((resolve) => {
        timer = setTimeout(resolve, remainingMs);
      });
      await Promise.race([completion, deadline]);
      if (timer !== undefined) clearTimeout(timer);
    }
    // Every worker absorbs item-level failures. If the deadline won the race,
    // the remaining promise only warms existing source caches in the background.
    void completion;
  }

  return Object.freeze(
    items.map((item, index) => hydrated[index] ?? item),
  );
}
