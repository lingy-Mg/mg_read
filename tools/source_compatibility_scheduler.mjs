/** Bounds independent source checks; a source keeps its own serial build/test
 * lifecycle. Drains every started worker before reporting unexpected failures,
 * and preserves input order independently of completion order. Owns no IO.
 */
export async function mapSources(items, concurrency, run) {
  if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > 8) {
    throw new RangeError('concurrency must be an integer from 1 to 8');
  }
  const results = new Array(items.length);
  const errors = [];
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (next < items.length) {
      const index = next++;
      try { results[index] = await run(items[index], index); }
      catch (error) { errors.push(error); }
    }
  }));
  if (errors.length) throw new AggregateError(errors, 'Source checks failed after all workers finished');
  return results;
}
