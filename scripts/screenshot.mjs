// Открывает дашборд в headless Chromium, проверяет, что все графики отрисованы
// без ошибок и предупреждений в консоли, и сохраняет скриншот в docs/dashboard.png.
// Запуск: npm install && npx playwright install chromium && node scripts/screenshot.mjs
// Код возврата 1 — если график не отрисован, в консоли есть ошибка/предупреждение
// или не загрузился какой-то файл.
import { chromium } from "playwright";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("../dashboard/", import.meta.url));
const OUT = fileURLToPath(new URL("../docs/dashboard.png", import.meta.url));
const TYPES = { ".html": "text/html; charset=utf-8", ".json": "application/json; charset=utf-8" };

// Минимальный статический сервер: страница берёт спеки и данные через fetch,
// а с file:// браузер их не отдаст.
const server = createServer(async (req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname)).replace(/^\/+/, "") || "index.html";
  const file = join(ROOT, path);
  if (!file.startsWith(ROOT)) { res.writeHead(403).end(); return; }  // только файлы dashboard/
  try {
    const body = await readFile(file);
    res.writeHead(200, { "content-type": TYPES[extname(path)] ?? "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
const url = `http://127.0.0.1:${server.address().port}/index.html`;

const problems = [];
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 }, deviceScaleFactor: 2 });
  page.on("console", (msg) => {
    if (msg.type() === "error" || msg.type() === "warning") problems.push(`console.${msg.type()}: ${msg.text()}`);
  });
  page.on("pageerror", (err) => problems.push(`pageerror: ${err.message}`));
  page.on("requestfailed", (r) => problems.push(`requestfailed: ${r.url()} ${r.failure()?.errorText}`));
  page.on("response", (r) => { if (r.status() >= 400) problems.push(`HTTP ${r.status()}: ${r.url()}`); });

  await page.goto(url, { waitUntil: "networkidle" });
  await page.waitForSelector("body[data-rendered]", { timeout: 30000 });
  const state = await page.evaluate(() => document.body.dataset.rendered);
  if (state !== "ok") problems.push(`страница сообщила: ${state}`);

  const charts = await page.$$eval("#kpi svg, .card svg.marks", (els) => els.length);
  const expected = 7;
  if (charts !== expected) problems.push(`отрисовано графиков: ${charts}, ожидалось ${expected}`);

  await page.screenshot({ path: OUT, fullPage: true });
  console.log(`скриншот: docs/dashboard.png (${url}), графиков: ${charts}`);
} finally {
  await browser.close();
  server.close();
}

if (problems.length) {
  console.error("ПРОБЛЕМЫ:\n" + problems.map((p) => "  " + p).join("\n"));
  process.exit(1);
}
console.log("ok: ошибок и предупреждений в консоли нет");
