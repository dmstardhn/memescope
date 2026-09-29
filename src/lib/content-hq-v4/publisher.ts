import "server-only";
import sharp from "sharp";
import { TwitterApi } from "twitter-api-v2";
import { getV4Settings, sqlV4 } from "./db";

type Row = Record<string, unknown>;

function credentials() {
  const appKey = process.env.X_API_KEY?.trim();
  const appSecret = process.env.X_API_SECRET?.trim();
  const accessToken = process.env.X_ACCESS_TOKEN?.trim();
  const accessSecret = process.env.X_ACCESS_SECRET?.trim();

  if (!appKey || !appSecret || !accessToken || !accessSecret) return null;
  return { appKey, appSecret, accessToken, accessSecret };
}

export function xPublishingConfigured() {
  return Boolean(credentials());
}

async function item(id: number) {
  const sql = sqlV4();
  const rows = await sql`SELECT * FROM memescope_content_v4_queue WHERE id=${id} LIMIT 1`;
  return rows.length ? rows[0] as Row : null;
}

async function publish(id: number) {
  const row = await item(id);
  if (!row) throw new Error("Content item not found.");

  const status = String(row.status ?? "");
  if (!["approved","scheduled"].includes(status)) {
    throw new Error(`Content status ${status} is not publishable.`);
  }

  const creds = credentials();
  if (!creds) throw new Error("X publishing is not configured.");

  const client = new TwitterApi(creds);
  let mediaIds: string[] = [];

  if (row.image_base64) {
    const input = Buffer.from(String(row.image_base64),"base64");
    const png = await sharp(input).png().toBuffer();
    const mediaId = await client.v1.uploadMedia(png,{mimeType:"image/png"});
    mediaIds = [mediaId];
  }

  const caption = String(row.caption ?? "").trim();
  if (!caption) throw new Error("Caption is empty.");

  const result = mediaIds.length
    ? await client.v2.tweet(caption,{media:{media_ids:mediaIds as [string]}})
    : await client.v2.tweet(caption);

  const tweetId = result.data.id;
  const sql = sqlV4();

  await sql`
    UPDATE memescope_content_v4_queue
    SET status='published',
        published_at=NOW(),
        x_post_id=${tweetId}
    WHERE id=${id}
  `;

  return {id,tweetId};
}

async function publicationGuard(force: boolean) {
  if (force) return;
  const settings = await getV4Settings();
  const sql = sqlV4();

  const today = await sql`
    SELECT COUNT(*)::INTEGER AS count
    FROM memescope_content_v4_queue
    WHERE status='published'
      AND published_at >= date_trunc('day', NOW() AT TIME ZONE 'Asia/Jakarta') AT TIME ZONE 'Asia/Jakarta'
  `;
  if (Number(today[0]?.count ?? 0) >= settings.maxPostsPerDay) throw new Error("Daily publish limit reached.");

  const latest = await sql`
    SELECT published_at
    FROM memescope_content_v4_queue
    WHERE status='published'
    ORDER BY published_at DESC
    LIMIT 1
  `;
  if (latest.length) {
    const gap = (Date.now()-new Date(String(latest[0].published_at)).getTime())/60000;
    if (gap < settings.minGapMinutes) throw new Error("Minimum publish gap is still active.");
  }
}

export async function publishNow(id: number, force = true) {
  await publicationGuard(force);
  const sql = sqlV4();
  await sql`
    UPDATE memescope_content_v4_queue
    SET status='approved', approved_at=COALESCE(approved_at,NOW())
    WHERE id=${id}
  `;
  return publish(id);
}

export async function scheduleIn(id: number, minutes: number) {
  const sql = sqlV4();
  const rows = await sql`
    UPDATE memescope_content_v4_queue
    SET status='scheduled',
        approved_at=COALESCE(approved_at,NOW()),
        scheduled_at=NOW()+(${minutes}::text || ' minutes')::interval
    WHERE id=${id}
    RETURNING scheduled_at
  `;
  if (!rows.length) throw new Error("Content item not found.");
  return new Date(String(rows[0].scheduled_at)).toISOString();
}

export async function publishDue() {
  if (!xPublishingConfigured()) return {published:0,reason:"x-not-configured"};

  const sql = sqlV4();
  const due = await sql`
    SELECT id
    FROM memescope_content_v4_queue
    WHERE status='scheduled'
      AND scheduled_at <= NOW()
    ORDER BY scheduled_at ASC
    LIMIT 1
  `;
  if (due.length) {
    try {
      await publicationGuard(false);
      const result = await publish(Number(due[0].id));
      return {published:1,result};
    } catch (error) {
      return {published:0,reason:error instanceof Error ? error.message : String(error)};
    }
  }

  const settings = await getV4Settings();
  if (settings.manualApproval) return {published:0,reason:"manual-approval"};

  const localHourRows = await sql`
    SELECT EXTRACT(HOUR FROM NOW() AT TIME ZONE 'Asia/Jakarta')::INTEGER AS hour
  `;
  const hour = Number(localHourRows[0]?.hour ?? -1);
  const insideWindow =
    (hour >= 8 && hour < 10) ||
    (hour >= 12 && hour < 14) ||
    (hour >= 17 && hour < 19) ||
    (hour >= 21 && hour < 23);

  if (!insideWindow) return {published:0,reason:"outside-posting-window"};

  const approved = await sql`
    SELECT id
    FROM memescope_content_v4_queue
    WHERE status='approved'
    ORDER BY created_at ASC
    LIMIT 1
  `;
  if (!approved.length) return {published:0,reason:"nothing-approved"};

  try {
    await publicationGuard(false);
    const result = await publish(Number(approved[0].id));
    return {published:1,result};
  } catch (error) {
    return {published:0,reason:error instanceof Error ? error.message : String(error)};
  }
}