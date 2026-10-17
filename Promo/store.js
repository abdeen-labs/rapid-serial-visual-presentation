// Composes App Store screenshots from raw simulator captures: each one a book cover in
// one of the app's cover tones, with a headline above the device.
//
//   bun store.js                 every shot in SHOTS → AppStore/Screenshots/<set>/
//   bun store.js --only 01,04    just those shots
//
// Raw captures live in AppStore/Captures/<set>/, named like the shot.

import puppeteer from "puppeteer-core";
import { mkdirSync, existsSync } from "node:fs";
import { join, dirname, extname } from "node:path";

const HERE = import.meta.dir;
const ROOT = dirname(HERE);

// The app's cover tones (CoverTone in DocumentCover.swift).
const TONE = {
  wine: "#4A1C2A", inkBlue: "#1C2B44", forest: "#1E3B30", plum: "#3D2344", tobacco: "#4B3424",
  deepTeal: "#16393D", slate: "#2E343B", olive: "#3F3D1E", indigo: "#221F40", rust: "#4F2C1C",
  moss: "#2A3A22", mauve: "#3A2A33",
};

// Screens in points, corner radii clockwise from the top left, and the frame's bezel.
// From the iPhone Duo simulator's device profile.
const DEVICE = {
  duoOuter: { points: { w: 466, h: 678 }, radii: [8, 59, 59, 8], bezel: 9, fold: "spine-left" },
  duoInner: { points: { w: 669, h: 951 }, radii: [55, 55, 55, 55], bezel: 8, fold: "horizontal" },
  duoInnerLandscape: { points: { w: 951, h: 669 }, radii: [55, 55, 55, 55], bezel: 8, fold: "vertical" },
};

// Canvas sizes App Store Connect accepts, and where the copy and devices sit on each,
// in thousandths of the canvas's short side.
const SET = {
  // The inner screen open in landscape, the iPhone Duo's natural open pose.
  "iPhone Duo": {
    size: { w: 2853, h: 2007 },
    device: "duoInnerLandscape",
    layout: {
      margin: 128, top: 88, eyebrow: 22, headline: 64, subtitle: 23, subWidth: 1250,
      gap1: 26, gap2: 26, rule: 72, deviceTop: 322, deviceW: 890, deviceGap: 70,
    },
  },
};

// Each shot's captures are AppStore/Captures/<set>/<capture>.png; a shot shows one device
// unless it lists several, left to right.
const SHOTS = [
  { id: "01", name: "one-word", tone: "inkBlue", eyebrow: "Speed reading", headline: "One w{o}rd at a time.",
    subtitle: "Each word lands in the same spot, so your eyes can stay still." },
  { id: "02", name: "folded-or-open", tone: "deepTeal", eyebrow: "iPhone Duo", headline: "F{o}lded or open.",
    subtitle: "Read one-handed on the outer screen, then open it up and keep going from the same word.",
    devices: [{ spec: "duoOuter", capture: "02-outer" }, { spec: "duoInnerLandscape", capture: "02-inner" }],
    layout: { deviceW: 760 } },
  { id: "03", name: "library", tone: "wine", eyebrow: "Your library", headline: "Every book, beautifully b{o}und.",
    subtitle: "Import EPUB, PDF, or text files. Continue Reading picks up at your exact word." },
  { id: "04", name: "hands-free", tone: "slate", eyebrow: "Hands-free", headline: "Two fingers, then let g{o}.",
    subtitle: "Tap with two fingers and the words keep coming on their own. Tap again to stop." },
  { id: "05", name: "chapters", tone: "plum", eyebrow: "Chapters", headline: "Every chapter, at a gl{a}nce.",
    subtitle: "See how long each chapter takes at your pace, and pick up right where you stopped." },
  { id: "06", name: "while-reading", tone: "tobacco", eyebrow: "While reading", headline: "Never lose the th{r}ead.",
    subtitle: "Show the words on either side, and any quote or parenthesis you're inside, at the size you like." },
  { id: "07", name: "make-it-yours", tone: "indigo", eyebrow: "Make it yours", headline: "Your words, your w{a}y.",
    subtitle: "Seven typefaces, four text colors, seven highlight colors, and true black for reading in the dark." },
  { id: "08", name: "timing", tone: "forest", eyebrow: "Smart timing", headline: "Pauses where a reader w{o}uld.",
    subtitle: "Commas, dashes, and sentence ends each get a pause, and long words get extra time." },
  { id: "09", name: "full-text", tone: "rust", eyebrow: "Full text", headline: "The whole page, one t{a}p away.",
    subtitle: "See where you are in the text, then tap any word to continue from there." },
];

const arg = (name, fallback) => {
  const i = process.argv.indexOf("--" + name);
  return i >= 0 ? process.argv[i + 1] : fallback;
};
const only = arg("only", null)?.split(",");

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

for (const shot of SHOTS) {
  if (only && !only.includes(shot.id)) continue;
  const setName = shot.set ?? "iPhone Duo";
  const set = SET[setName];
  const devices = (shot.devices ?? [{ spec: set.device, capture: shot.id }]).map(({ spec, capture }) => {
    const screen = `/AppStore/Captures/${setName}/${capture}.png`;
    if (!existsSync(join(ROOT, screen))) throw new Error(`missing capture ${screen}`);
    return { spec: DEVICE[spec], screen };
  });
  await page.setViewport({ width: set.size.w, height: set.size.h, deviceScaleFactor: 1 });
  await page.goto(`http://localhost:${server.port}/Promo/store.html`);
  await page.evaluate((s) => window.compose(s), {
    ...shot,
    size: set.size,
    devices,
    layout: { ...set.layout, ...shot.layout },
    tone: TONE[shot.tone],
  });
  const dir = join(ROOT, "AppStore", "Screenshots", setName);
  mkdirSync(dir, { recursive: true });
  const file = join(dir, `${shot.id}-${shot.name}.png`);
  await page.screenshot({ path: file });
  console.log(file);
}

await browser.close();
server.stop();
