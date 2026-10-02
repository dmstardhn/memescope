import "server-only";

import { neon } from "@neondatabase/serverless";

export const CONTENT_TIERS = [
  "momentum",
  "breakout",
  "surge",
  "apex",
  "legend",
  "titan",
  "century",
] as const;

export type ContentTier = (typeof CONTENT_TIERS)[number];

type DbRow = Record<string, unknown>;

function sqlClient() {
  const url = process.env.DATABASE_URL?.trim();
  if (!url) throw new Error("DATABASE_URL is not configured.");
  return neon(url);
}

function botToken() {
  const value = process.env.TELEGRAM_BOT_TOKEN?.trim();
  if (!value) throw new Error("TELEGRAM_BOT_TOKEN is not configured.");
  return value;
}

let schemaPromise: Promise<void> | null = null;

export async function ensureContentBackgroundSchema() {
  if (schemaPromise) return schemaPromise;

  schemaPromise = (async () => {
    const sql = sqlClient();

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_content_card_backgrounds (
        tier TEXT PRIMARY KEY,
        telegram_file_id TEXT,
        telegram_file_unique_id TEXT,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    for (const tier of CONTENT_TIERS) {
      await sql`
        INSERT INTO memescope_content_card_backgrounds (tier)
        VALUES (${tier})
        ON CONFLICT (tier) DO NOTHING
      `;
    }

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_content_card_background_pending (
        owner_id BIGINT PRIMARY KEY,
        chat_id BIGINT NOT NULL,
        tier TEXT NOT NULL,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_content_v5_daily (
        report_key TEXT PRIMARY KEY,
        telegram_message_id BIGINT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;
  })().catch((error) => {
    schemaPromise = null;
    throw error;
  });

  return schemaPromise;
}

export function tierFromMultiple(multiple: number): ContentTier {
  if (multiple >= 100) return "century";
  if (multiple >= 50) return "titan";
  if (multiple >= 20) return "legend";
  if (multiple >= 10) return "apex";
  if (multiple >= 5) return "surge";
  if (multiple >= 3) return "breakout";
  return "momentum";
}

export function tierTitle(tier: ContentTier) {
  return tier.toUpperCase();
}

export async function listContentBackgrounds() {
  await ensureContentBackgroundSchema();
  const sql = sqlClient();
  const rows = await sql`
    SELECT tier, telegram_file_id, telegram_file_unique_id, updated_at
    FROM memescope_content_card_backgrounds
    ORDER BY CASE tier
      WHEN 'momentum' THEN 1
      WHEN 'breakout' THEN 2
      WHEN 'surge' THEN 3
      WHEN 'apex' THEN 4
      WHEN 'legend' THEN 5
      WHEN 'titan' THEN 6
      WHEN 'century' THEN 7
      ELSE 99 END
  `;

  return rows.map((raw: DbRow) => {
    const row = raw as DbRow;
    return {
      tier: String(row.tier) as ContentTier,
      configured: Boolean(row.telegram_file_id),
      fileId: row.telegram_file_id ? String(row.telegram_file_id) : null,
      updatedAt: row.updated_at ? String(row.updated_at) : null,
    };
  });
}

export async function getBackgroundFileId(tier: ContentTier) {
  await ensureContentBackgroundSchema();
  const sql = sqlClient();
  const rows = await sql`
    SELECT telegram_file_id
    FROM memescope_content_card_backgrounds
    WHERE tier = ${tier}
    LIMIT 1
  `;
  const value = rows[0]?.telegram_file_id;
  return value ? String(value) : null;
}

export async function setContentBackground(
  tier: ContentTier,
  fileId: string,
  uniqueId: string | null,
) {
  await ensureContentBackgroundSchema();
  const sql = sqlClient();
  await sql`
    INSERT INTO memescope_content_card_backgrounds (
      tier, telegram_file_id, telegram_file_unique_id, updated_at
    ) VALUES (
      ${tier}, ${fileId}, ${uniqueId}, NOW()
    )
    ON CONFLICT (tier) DO UPDATE SET
      telegram_file_id = EXCLUDED.telegram_file_id,
      telegram_file_unique_id = EXCLUDED.telegram_file_unique_id,
      updated_at = NOW()
  `;
}

export async function resetContentBackground(tier: ContentTier) {
  await ensureContentBackgroundSchema();
  const sql = sqlClient();
  await sql`
    UPDATE memescope_content_card_backgrounds
    SET telegram_file_id = NULL,
        telegram_file_unique_id = NULL,
        updated_at = NOW()
    WHERE tier = ${tier}
  `;
}

export async function setPendingBackgroundTier(
  ownerId: number,
  chatId: number,
  tier: ContentTier,
) {
  await ensureContentBackgroundSchema();
  const sql = sqlClient();
  await sql`
    INSERT INTO memescope_content_card_background_pending (
      owner_id, chat_id, tier, updated_at
    ) VALUES (
      ${ownerId}, ${chatId}, ${tier}, NOW()
    )
    ON CONFLICT (owner_id) DO UPDATE SET
      chat_id = EXCLUDED.chat_id,
      tier = EXCLUDED.tier,
      updated_at = NOW()
  `;
}

export async function pendingBackgroundTier(ownerId: number) {
  await ensureContentBackgroundSchema();
  const sql = sqlClient();
  const rows = await sql`
    SELECT chat_id, tier
    FROM memescope_content_card_background_pending
    WHERE owner_id = ${ownerId}
    LIMIT 1
  `;
  if (!rows.length) return null;
  return {
    chatId: Number(rows[0].chat_id),
    tier: String(rows[0].tier) as ContentTier,
  };
}

export async function clearPendingBackgroundTier(ownerId: number) {
  await ensureContentBackgroundSchema();
  const sql = sqlClient();
  await sql`
    DELETE FROM memescope_content_card_background_pending
    WHERE owner_id = ${ownerId}
  `;
}

export async function telegramFileBuffer(fileId: string) {
  const token = botToken();
  const response = await fetch(
    `https://api.telegram.org/bot${token}/getFile?file_id=${encodeURIComponent(fileId)}`,
    { cache: "no-store" },
  );
  const body = (await response.json()) as {
    ok?: boolean;
    result?: { file_path?: string };
    description?: string;
  };
  const filePath = body.result?.file_path;
  if (!response.ok || !body.ok || !filePath) {
    throw new Error(body.description ?? "Telegram getFile failed.");
  }

  const fileResponse = await fetch(
    `https://api.telegram.org/file/bot${token}/${filePath}`,
    { cache: "no-store" },
  );
  if (!fileResponse.ok) {
    throw new Error(`Telegram file download failed: ${fileResponse.status}`);
  }
  return Buffer.from(await fileResponse.arrayBuffer());
}
