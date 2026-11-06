// Captures the dashboard pages as full-page PNGs with Playwright.
// Usage: node capture-dashboard.cjs URL TOKEN OUT_DIR (scripts/dashboard-screenshots runs it).
const { chromium } = require("playwright");

const [url, token, out] = process.argv.slice(2);

// name, path, seconds to wait for data after the LiveView connects
const pages = [
  ["workers", "/workers?worker=counter", 1],
  ["deployments", "/deployments", 1],
  ["routes", "/routes", 1],
  ["cells", "/cells?limit=10", 1],
  ["alarms", "/alarms?limit=15", 1],
  ["jobs", "/jobs?cell=jobs.job-1", 1],
  ["metrics-requests", "/metrics?nav=requests", 15],
  ["metrics-native", "/metrics?nav=wasm_native", 15],
];

(async () => {
  const browser = await chromium.launch();
  try {
    for (const [name, path, wait] of pages) {
      const context = await browser.newContext({ viewport: { width: 1400, height: 900 } });
      const page = await context.newPage();
      const sep = path.includes("?") ? "&" : "?";
      await page.goto(`${url}${path}${sep}token=${token}`);
      await page.waitForSelector("[data-phx-main].phx-connected");
      await page.waitForTimeout(wait * 1000);
      await page.screenshot({ path: `${out}/dashboard-${name}.png`, fullPage: true });
      console.log(`${out}/dashboard-${name}.png`);
      await context.close();
    }
  } finally {
    await browser.close();
  }
})();
