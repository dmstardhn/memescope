import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const relative = "src/app/api/telegram/webhook/route.ts";
const file = path.join(root, relative);

function fail(message) {
  console.error(`\nERROR: ${message}\n`);
  process.exit(1);
}

if (!fs.existsSync(file)) {
  fail(`File not found: ${relative}`);
}

let source = fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n");

if (!source.includes("telegramSendMessage")) {
  fail("telegramSendMessage marker was not found in the Telegram webhook.");
}

if (!source.includes("type InlineKeyboard") && !source.includes("interface InlineKeyboard")) {
  fail("InlineKeyboard type was not found. Stop here so this fix does not guess your webhook structure.");
}

if (source.includes("async function reply(")) {
  console.log("reply() helper already exists. Nothing changed.");
  console.log("Next: npm run typecheck");
  process.exit(0);
}

const marker = "async function showSettings(";
const at = source.indexOf(marker);
if (at < 0) {
  fail("showSettings() marker was not found.");
}

const helper = `async function reply(\n  chatId: number,\n  messageId:\n    number | undefined,\n  text: string,\n  keyboard?: InlineKeyboard,\n) {\n  return telegramSendMessage(\n    chatId,\n    text,\n    {\n      replyToMessageId:\n        messageId,\n      ...(keyboard\n        ? {\n            replyMarkup:\n              keyboard as unknown as Record<\n                string,\n                unknown\n              >,\n          }\n        : {}),\n    },\n  );\n}\n\n`;

const stamp = new Date().toISOString().replace(/[:.]/g, "-");
const backupDir = path.join(
  root,
  ".memescope-backups",
  `v21-reply-fix-${stamp}`,
);
const backupFile = path.join(backupDir, relative);
fs.mkdirSync(path.dirname(backupFile), { recursive: true });
fs.copyFileSync(file, backupFile);

source = source.slice(0, at) + helper + source.slice(at);
fs.writeFileSync(file, source, "utf8");

const verification = fs.readFileSync(file, "utf8");
if (!verification.includes("async function reply(")) {
  fail("Verification failed after writing reply() helper.");
}

fs.rmSync(path.join(root, ".next"), {
  recursive: true,
  force: true,
});

console.log("");
console.log("============================================================");
console.log(" MemeScope V21 Telegram reply() fix installed");
console.log("============================================================");
console.log("");
console.log(`Updated: ${relative}`);
console.log(`Backup:  ${backupDir}`);
console.log("");
console.log("This fix ONLY restores the Telegram reply() helper.");
console.log("Signal engine, presets, Call Story and Content HQ were not changed.");
console.log("");
console.log("Next:");
console.log(" npm run typecheck");
console.log(" npm run build");
