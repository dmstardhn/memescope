import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const backupRoot = path.join(root, '.memescope-backups', `v21-test-no-tp-${stamp}`);

const targets = [
  'src/lib/telegram-photo.ts',
  'src/app/api/telegram/card/test/route.tsx',
];

function ensureFile(rel) {
  const abs = path.join(root, rel);
  if (!fs.existsSync(abs)) {
    throw new Error(`Required file not found: ${rel}`);
  }
  return abs;
}

function backup(rel) {
  const src = ensureFile(rel);
  const dest = path.join(backupRoot, rel);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.copyFileSync(src, dest);
}

for (const rel of targets) backup(rel);

// ------------------------------------------------------------
// 1) Telegram test caption: remove legacy Potential TP wording.
// ------------------------------------------------------------
{
  const rel = 'src/lib/telegram-photo.ts';
  const abs = ensureFile(rel);
  let s = fs.readFileSync(abs, 'utf8');
  const before = s;

  // Most common Stage 18 caption line.
  s = s.replace(
    /["']Potential TP:\s*<b>\+31\.5%<\/b>["'],?/g,
    '"Status: <b>LIVE</b>",',
  );

  // Fallback: any Potential TP caption line.
  s = s.replace(
    /^\s*["'][^"']*Potential TP[^"']*["'],?\s*$/gim,
    '          "Status: <b>LIVE</b>",',
  );

  // Update the test note to Stage 21 wording when the old one is present.
  s = s.replace(
    /This is a Stage 18 image-card test, not a live trading signal\./g,
    'This is a MemeScope V21 formatting test, not a live trading signal.',
  );

  if (s === before) {
    console.warn(`No legacy Potential TP caption text found in ${rel}; left unchanged.`);
  } else {
    fs.writeFileSync(abs, s, 'utf8');
    console.log(`Updated: ${rel}`);
  }
}

// ------------------------------------------------------------
// 2) Test image card: replace POTENTIAL TP cell with LIVE status.
// ------------------------------------------------------------
{
  const rel = 'src/app/api/telegram/card/test/route.tsx';
  const abs = ensureFile(rel);
  let s = fs.readFileSync(abs, 'utf8');
  const before = s;

  s = s.replace(
    /\[\s*["']POTENTIAL TP["']\s*,\s*["']\+31\.5%["']\s*\]/g,
    '["STATUS", "LIVE"]',
  );

  // Fallback for formatting variations.
  s = s.replace(/POTENTIAL TP/g, 'STATUS');
  s = s.replace(/\+31\.5%/g, 'LIVE');

  if (s === before) {
    console.warn(`No legacy POTENTIAL TP card cell found in ${rel}; left unchanged.`);
  } else {
    fs.writeFileSync(abs, s, 'utf8');
    console.log(`Updated: ${rel}`);
  }
}

// Clear stale Next.js output so the next build/test cannot reuse old generated files.
const nextDir = path.join(root, '.next');
if (fs.existsSync(nextDir)) {
  fs.rmSync(nextDir, { recursive: true, force: true });
  console.log('Removed stale .next cache');
}

console.log('');
console.log('============================================================');
console.log(' MemeScope V21 test formatter: Potential TP removed');
console.log('============================================================');
console.log(`Backup: ${backupRoot}`);
console.log('');
console.log('Next:');
console.log(' npm run typecheck');
console.log(' npm run build');
