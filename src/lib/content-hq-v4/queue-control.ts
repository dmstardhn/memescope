import "server-only";
import { getV4Settings, sqlV4, type ContentType } from "./db";
import { renderContent, type Candle } from "./render";

type Row = Record<string, unknown>;

const CAPTIONS: Record<ContentType, string[]> = {
  market_observation: [
    "small caps getting more active today.\n\nwatching volume before chasing anything.",
    "market activity is picking up a bit.\n\nstill being selective.",
    "not much worth forcing here.\n\nwaiting for cleaner setups.",
  ],
  token_watch: [
    "$TOKEN starting to get interesting here.\n\nwatching the next push.",
    "$TOKEN\n\ninteresting structure developing.\n\nnot there yet.",
  ],
  chart_setup: [
    "$TOKEN\n\nwatching this structure.",
    "$TOKEN starting to look interesting around this area.",
    "$TOKEN\n\nwatching for a clean continuation.",
  ],
  token_update: [
    "$TOKEN update.\n\nnice reaction from the level.",
    "$TOKEN still holding up well.\n\nwatching continuation.",
    "$TOKEN\n\nclean move from the area.",
  ],
  before_move: [
    "$TOKEN\n\nfirst spotted around $FIRST_MC.\nnow sitting near $CURRENT_MC.\n\n$MULTIPLE since detection.",
    "$TOKEN before the move.\n\n$FIRST_MC -> $CURRENT_MC\n\n$MULTIPLE.",
  ],
  call_journey: [
    "$TOKEN journey so far.\n\n$FIRST_MC -> $CURRENT_MC\n\n$MULTIPLE since detection.",
    "$TOKEN kept developing after the first detection.\n\nnow at $MULTIPLE.",
  ],
  daily_recap: [
    "today's tape.\n\n$TOKEN was the standout tracked move at $MULTIPLE.",
  ],
  weekly_recap: [
    "weekly tape.\n\n$TOKEN was one of the stronger tracked moves at $MULTIPLE.",
  ],
};

const STYLES = ["pure_chart","level_setup","first_spotted","minimal_metrics","performance"];

function num(v: unknown): number | null {
  const x = Number(v);
  return Number.isFinite(x) ? x : null;
}
function txt(v: unknown) { return v == null ? "" : String(v); }
function usd(v: number | null) {
  if (v == null || !Number.isFinite(v)) return "N/A";
  if (v >= 1e9) return `$${(v/1e9).toFixed(2)}B`;
  if (v >= 1e6) return `$${(v/1e6).toFixed(2)}M`;
  if (v >= 1e3) return `$${(v/1e3).toFixed(0)}K`;
  return `$${v.toFixed(0)}`;
}
function fill(template: string, symbol: string, firstMc: number | null, currentMc: number | null, multiple: number | null) {
  return template
    .replaceAll("$TOKEN", `$${symbol}`)
    .replaceAll("$FIRST_MC", usd(firstMc))
    .replaceAll("$CURRENT_MC", usd(currentMc))
    .replaceAll("$MULTIPLE", multiple ? `${multiple.toFixed(2)}x` : "N/A");
}

async function candles(pair: string | null) {
  if (!pair) return [] as Candle[];
  try {
    const r = await fetch(
      `https://api.geckoterminal.com/api/v2/networks/solana/pools/${encodeURIComponent(pair)}/ohlcv/minute?aggregate=5&limit=100&currency=usd&token=base`,
      { headers: { Accept: "application/json;version=20230203" }, cache: "no-store" },
    );
    if (!r.ok) return [];
    const body = await r.json() as {data?: {attributes?: {ohlcv_list?: number[][]}}};
    return (body.data?.attributes?.ohlcv_list ?? [])
      .map(row => ({
        timestamp: Number(row[0])*1000,
        open:Number(row[1]), high:Number(row[2]), low:Number(row[3]),
        close:Number(row[4]), volume:Number(row[5]??0),
      }))
      .filter(x => Number.isFinite(x.close) && x.close > 0)
      .sort((a,b)=>a.timestamp-b.timestamp);
  } catch { return []; }
}

export async function listPending(limit = 5) {
  const settings = await getV4Settings();
  const sql = sqlV4();
  return await sql`
    SELECT *
    FROM memescope_content_v4_queue
    WHERE created_at >= ${settings.historyResetAt}::timestamptz
      AND status IN ('queued','approved','scheduled')
    ORDER BY created_at DESC
    LIMIT ${limit}
  ` as Row[];
}

export async function getItem(id: number) {
  const sql = sqlV4();
  const rows = await sql`SELECT * FROM memescope_content_v4_queue WHERE id=${id} LIMIT 1`;
  return rows.length ? rows[0] as Row : null;
}

export async function approve(id: number) {
  const sql = sqlV4();
  await sql`UPDATE memescope_content_v4_queue SET status='approved', approved_at=NOW() WHERE id=${id}`;
}

export async function reject(id: number) {
  const sql = sqlV4();
  await sql`UPDATE memescope_content_v4_queue SET status='rejected' WHERE id=${id}`;
}

export async function nextCaption(id: number) {
  const item = await getItem(id);
  if (!item) throw new Error("Queue item not found.");
  const type = txt(item.content_type) as ContentType;
  const list = CAPTIONS[type] ?? [];
  if (!list.length) return;

  const currentKey = txt(item.caption_template);
  const currentNum = Number(currentKey.split("_").at(-1) ?? 1);
  const nextIndex = Number.isFinite(currentNum) ? currentNum % list.length : 0;
  const key = `${type}_${String(nextIndex+1).padStart(2,"0")}`;
  const caption = fill(
    list[nextIndex],
    txt(item.symbol),
    num(item.first_market_cap),
    num(item.current_market_cap),
    num(item.multiple),
  );

  const sql = sqlV4();
  await sql`
    UPDATE memescope_content_v4_queue
    SET caption_template=${key}, caption=${caption}
    WHERE id=${id}
  `;
}

export async function nextVisual(id: number) {
  const item = await getItem(id);
  if (!item) throw new Error("Queue item not found.");

  const type = txt(item.content_type) as ContentType;
  if (type === "market_observation") return;

  let next = "pure_chart";
  if (type === "before_move") next = "split_before_now";
  else if (type === "call_journey") next = "journey";
  else {
    const current = txt(item.visual_style);
    const idx = STYLES.indexOf(current);
    next = STYLES[(idx + 1) % STYLES.length];
  }

  const liveCandles = await candles(txt(item.pair_address) || null);
  if (liveCandles.length < 2) throw new Error("Chart data unavailable.");

  const rendered = await renderContent({
    symbol: txt(item.symbol),
    contentType: type,
    visualStyle: next,
    firstMarketCap: num(item.first_market_cap),
    currentMarketCap: num(item.current_market_cap),
    multiple: num(item.multiple),
    liquidity: null,
    volume: null,
    candles: liveCandles,
    branded: Boolean(item.branded),
  });

  if (!rendered) throw new Error("Visual could not be rendered.");

  const sql = sqlV4();
  await sql`
    UPDATE memescope_content_v4_queue
    SET visual_style=${next},
        image_base64=${rendered.buffer.toString("base64")},
        image_mime=${rendered.mime}
    WHERE id=${id}
  `;
}