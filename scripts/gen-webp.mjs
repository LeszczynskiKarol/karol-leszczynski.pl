// Generates WebP siblings for every JPG/PNG under public/.
// Run before `astro build`. Skips files whose .webp is newer than source.
import sharp from "sharp";
import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..", "public");
const QUALITY = 80;

async function* walk(dir) {
  for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(p);
    else yield p;
  }
}

let made = 0, skipped = 0, failed = 0;

for await (const file of walk(ROOT)) {
  const ext = path.extname(file).toLowerCase();
  if (ext !== ".jpg" && ext !== ".jpeg" && ext !== ".png") continue;

  const out = file.slice(0, -ext.length) + ".webp";
  try {
    const srcStat = await fs.stat(file);
    const outStat = await fs.stat(out).catch(() => null);
    if (outStat && outStat.mtimeMs >= srcStat.mtimeMs) { skipped++; continue; }

    await sharp(file).webp({ quality: QUALITY, effort: 5 }).toFile(out);
    made++;
    console.log("  +", path.relative(ROOT, out));
  } catch (e) {
    failed++;
    console.error("  ! failed:", path.relative(ROOT, file), e.message);
  }
}

console.log(`\nWebP: ${made} generated, ${skipped} up-to-date, ${failed} failed`);
