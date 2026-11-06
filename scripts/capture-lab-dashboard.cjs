// Captures the dashboard of the cluster lab with Playwright: three nodes, the node selector, and the
// automatic refresh when a node is lost.
// Usage: node capture-lab-dashboard.cjs URL TOKEN OUT_DIR FAULT_COMMAND (scripts/lab-dashboard-screenshots runs it).
const { chromium } = require("playwright");
const { execSync } = require("child_process");

const [url, token, out, fault] = process.argv.slice(2);

async function open(browser, path) {
  const context = await browser.newContext({ viewport: { width: 1400, height: 900 } });
  const page = await context.newPage();
  const sep = path.includes("?") ? "&" : "?";
  await page.goto(`${url}${path}${sep}token=${token}`);
  await page.waitForSelector("[data-phx-main].phx-connected");
  return page;
}

async function shot(page, name) {
  const file = `${out}/lab-${name}.png`;
  await page.screenshot({ path: file, fullPage: true });
  console.log(file);
}

(async () => {
  const browser = await chromium.launch();
  try {
    // 1. Three nodes serving, and the cells of each node through the node selector.
    const deployments = await open(browser, "/deployments");
    await deployments.waitForTimeout(2000);
    await shot(deployments, "deployments-three-nodes");

    const cells = await open(browser, "/cells");
    const nodes = await cells.$$eval("#node-select option", (o) => o.map((e) => e.value));
    for (const [i, node] of nodes.entries()) {
      if (i > 0) {
        await cells.selectOption("#node-select", node);
        await cells.waitForURL(`**/${encodeURIComponent(node)}/cells`);
      }
      await cells.waitForTimeout(2000);
      await shot(cells, `cells-node-${i + 1}`);
    }

    const metrics = await open(browser, "/metrics?nav=cluster");
    await metrics.waitForTimeout(15000);
    await shot(metrics, "metrics-cluster");

    // 2. Automatic refresh: the page stays open, a node is lost, and the table changes without a reload.
    await deployments.selectOption("#refresh-interval-select", "2");
    execSync(fault);
    await deployments.waitForTimeout(15000);
    await shot(deployments, "deployments-node-lost");
    const lost = await open(browser, "/cells");
    await lost.waitForTimeout(40000);
    await shot(lost, "cells-node-lost");
  } finally {
    await browser.close();
  }
})();
