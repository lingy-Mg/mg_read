/** Deterministic Source workload; all data is synthetic and HTTP stays local.
 * Exercises CPU/JSON work and real Source result validation/transport without
 * site latency, cookies, parser drift or production data influencing the run.
 */
import { createHash } from "node:crypto";
import { cpuUsage } from "node:process";

let context;
export function activate(value) { context = value; }
const text = "Benchmark chapter text. ".repeat(2048);
function summary(title, index = 0) {
  return {
    id: `book:${index}`, title, contentKind: "novel", author: "Benchmark",
    url: null, coverUrl: null, description: "Synthetic benchmark", language: "en",
    status: "ongoing", access: "free", wordCount: null, chapterCount: 5000,
    publishedAt: null, updatedAt: null, latestChapter: null,
    categories: [], tags: [], attributes: [],
  };
}
export function discover() {
  return { kind: "document", document: { components: [] } };
}
export async function search(request) {
  let title = "benchmark";
  if (request.query === "cpu") {
    const rows = Array.from({ length: 4000 }, (_, i) => ({ id: i, title: `Book ${i}`, score: (i * 97) % 4001 }));
    const parsed = JSON.parse(JSON.stringify(rows)).sort((a, b) => b.score - a.score);
    title = createHash("sha256").update(JSON.stringify(parsed)).digest("hex");
  } else if (request.query === "cpuUsage") {
    title = JSON.stringify(cpuUsage());
  } else if (request.query.startsWith("http:")) {
    const port = request.query.split(":")[1];
    const response = await context.http.fetch(`http://127.0.0.1:${port}/sample?nonce=${request.query.split(":")[2]}`);
    title = String((await response.text()).length);
  }
  return { items: [summary(title)], nextCursor: null, totalCount: 1 };
}
export function getDetail(request) {
  return { ...summary("Benchmark"), id: request.id, aliases: [], catalogUrl: null };
}
export function getChapters() {
  return { items: Array.from({ length: 5000 }, (_, i) => ({
    id: `chapter:${i}`, title: `Chapter ${i}`, order: i, url: null,
    volumeTitle: null, wordCount: null, updatedAt: null, isLocked: false, attributes: [],
  })) };
}
export function getContent(request) {
  return { contentKind: "novel", chapterId: request.chapterId, title: "Benchmark", updatedAt: null, text, pages: [] };
}
