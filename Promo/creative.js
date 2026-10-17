// Composes the App Store's creative assets: the product page header and the search
// results image, at the sizes App Store Connect accepts.
//
//   bun creative.js           every asset → AppStore/Creative/
//   bun creative.js --safe    with Apple's art safe area outlined → Promo/out/ (for checking)
//
// Safe areas are from Apple's creative-assets template (Sketch, "Art Safe Area").

import puppeteer from "puppeteer-core";
import { mkdirSync, existsSync } from "node:fs";
import { join, dirname, extname } from "node:path";

const HERE = import.meta.dir;
const ROOT = dirname(HERE);
const showSafe = process.argv.includes("--safe");

// iPhone 18 Pro Max, from the simulator's device profile (points, 62 pt corners).
const IPHONE = { points: { w: 440, h: 956 }, radius: 62, bezel: 6, island: { w: 126, h: 37, y: 11 } };

const ASSETS = [
  // 21:9. On iPhone little more than the safe area shows, so the whole line fits in it.
  { name: "header", kind: "header", size: { w: 3840, h: 1646 }, safe: { x: 1097, y: 493, w: 1646, h: 661 },
    text: "One word at a time.", wordIndex: 1, width: 1560, gap: 0.34,
    nearest: 0.55, falloff: 0.88, farthest: 0.4, guideWidth: 6, guideOpacity: 0.25 },
  // 3:2, the largest size accepted.
  { name: "search-results", kind: "search", size: { w: 3840, h: 2560 }, safe: { x: 836, y: 765, w: 2168, h: 1030 },
    tone: "#1C2B44", // inkBlue, as in screenshot 01
    headline: { text: "Speed read\none w{o}rd\nat a time.", size: 80 },
    copyLeft: 900, phone: { height: 2200, top: 180, centerX: 2480 },
    device: IPHONE, screen: "/AppStore/Captures/Creative/iphone-reader.png" },
];

const TYPES = { ".html": "text/html", ".js": "text/javascript", ".ttf": "font/ttf", ".png": "image/png" };
const server = Bun.serve({
  port: 0,
  fetch(req) {
    const path = join(ROOT, decodeURIComponent(new URL(req.url).pathname));
    if (!path.startsWith(ROOT) || !existsSync(path)) return new Response("not found", { status: 404 });
    return new Response(Bun.file(path), {
      headers: { "content-type": TYPES[extname(path)] ?? "application/octet-stream" },
    });
  },
});

const browser = await puppeteer.launch({
  executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  headless: true,
  args: ["--force-color-profile=srgb", "--font-render-hinting=none"],
});
const page = await browser.newPage();
const dir = showSafe ? join(HERE, "out") : join(ROOT, "AppStore", "Creative");
mkdirSync(dir, { recursive: true });

for (const asset of ASSETS) {
  await page.setViewport({ width: asset.size.w, height: asset.size.h, deviceScaleFactor: 1 });
  await page.goto(`http://localhost:${server.port}/Promo/creative.html`);
  await page.evaluate((a) => window.compose(a), { ...asset, showSafe });
  const file = join(dir, `${asset.name}${showSafe ? "-safe" : ""}.png`);
  await page.screenshot({ path: file });
  console.log(file);
}

await browser.close();
server.stop();
