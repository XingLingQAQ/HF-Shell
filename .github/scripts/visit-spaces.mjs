import fs from "node:fs/promises";
import path from "node:path";
import { chromium } from "playwright-core";

const urls = (process.env.SPACE_URLS || "")
    .split(/[\n,]/)
    .map((url) => url.trim())
    .filter(Boolean);

if (urls.length === 0) {
    throw new Error("No Space URLs were configured.");
}

const artifactsDirectory = path.resolve("space-visit-artifacts");
await fs.mkdir(artifactsDirectory, { recursive: true });

const browser = await chromium.launch({
    headless: false,
    executablePath: process.env.BROWSER_EXECUTABLE_PATH || undefined,
});

let failures = 0;

try {
    for (const [index, url] of urls.entries()) {
        const context = await browser.newContext();
        const page = await context.newPage();

        console.log(`Visiting ${url}`);

        try {
            const response = await page.goto(url, {
                waitUntil: "domcontentloaded",
                timeout: 45000,
            });

            await page.waitForTimeout(5000);
            await page.waitForLoadState("load", { timeout: 15000 }).catch((error) => {
                console.warn(`Load event did not complete for ${url}: ${error.message}`);
            });

            const status = response?.status() ?? 0;
            const title = await page.title().catch(() => "");
            await page.screenshot({
                path: path.join(artifactsDirectory, `${index + 1}.png`),
                fullPage: true,
            });

            console.log(JSON.stringify({ url, status, finalUrl: page.url(), title }));

            if (status < 200 || status >= 400) {
                failures += 1;
                console.error(`Unexpected HTTP status ${status} for ${url}`);
            }
        } catch (error) {
            failures += 1;
            console.error(`Browser visit failed for ${url}: ${error.message}`);

            await page
                .screenshot({
                    path: path.join(artifactsDirectory, `${index + 1}-error.png`),
                    fullPage: true,
                })
                .catch(() => undefined);
        } finally {
            await context.close();
        }
    }
} finally {
    await browser.close();
}

if (failures > 0) {
    process.exitCode = 1;
}
