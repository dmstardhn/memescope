import "server-only";
import {
  ensureV4Schema,
  getV4Settings,
  sqlV4,
  type ContentType,
} from "./db";
import {
  CHART_STYLES,
  renderContent,
  type Candle,
} from "./render";

type RawRow = Record<string, unknown>;

type Market = {
  pairAddress: string | null;
  currentMc: number | null;
  liquidity: number | null;
  volume: number | null;
};

type Candidate = {
  eventKey: string;
  tokenAddress: string | null;
  pairAddress: string | null;
  symbol: string;
  contentType: ContentType;
  visualStyle: string;
  captionTemplate: string;
  caption: string;
  reason: string;
  firstMc: number | null;
  currentMc: number | null;
  multiple: number | null;
  liquidity: number | null;
  volume: number | null;
  branded: boolean;
  candles: Candle[];
  historicCandles?: Candle[];
};

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

function num(v: unknown): number | null {
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function str(v: unknown): string | null {
  if (v === null || v === undefined) return null;
  const s = String(v).trim();
  return s ? s : null;
}

function pick(row: RawRow, keys: string[]) {
  for (const key of keys) if (row[key] !== undefined && row[key] !== null) return row[key];
  return null;
}

function compactUsd(value: number | null) {
  if (value === null || !Number.isFinite(value)) return "N/A";
  if (value >= 1e9) return `$${(value/1e9).toFixed(2)}B`;
  if (value >= 1e6) return `$${(value/1e6).toFixed(2)}M`;
  if (value >= 1e3) return `$${(value/1e3).toFixed(0)}K`;
  return `$${value.toFixed(0)}`;
}

function fill(template: string, symbol: string, firstMc: number | null, currentMc: number | null, multiple: number | null) {
  return template
    .replaceAll("$TOKEN", `$${symbol}`)
    .replaceAll("$FIRST_MC", compactUsd(firstMc))
    .replaceAll("$CURRENT_MC", compactUsd(currentMc))
    .replaceAll("$MULTIPLE", multiple ? `${multiple.toFixed(2)}x` : "N/A");
}

async function market(tokenAddress: string, preferredPair: string | null): Promise<Market> {
  try {
    const r = await fetch(`https://api.dexscreener.com/latest/dex/tokens/${encodeURIComponent(tokenAddress)}`, {
      headers: { Accept: "application/json" },
      cache: "no-store",
    });
    if (!r.ok) throw new Error("DEX API failed");
    const body = await r.json() as {pairs?: Array<Record<string, any>>};
    const pairs = (body.pairs ?? []).filter(p => p.chainId === "solana");
    const p = pairs.find(x => preferredPair && x.pairAddress === preferredPair)
      ?? pairs.sort((a,b) => Number(b.liquidity?.usd ?? 0)-Number(a.liquidity?.usd ?? 0))[0];
    if (!p) throw new Error("No Solana pair");
    return {
      pairAddress: str(p.pairAddress),
      currentMc: num(p.marketCap ?? p.fdv),
      liquidity: num(p.liquidity?.usd),
      volume: num(p.volume?.h24),
    };
  } catch {
    return { pairAddress: preferredPair, currentMc: null, liquidity: null, volume: null };
  }
}

async function candleSeries(pair: string | null, beforeTimestamp?: number) {
  if (!pair) return [] as Candle[];
  try {
    const before = beforeTimestamp ? `&before_timestamp=${Math.floor(beforeTimestamp/1000)}` : "";
    const r = await fetch(
      `https://api.geckoterminal.com/api/v2/networks/solana/pools/${encodeURIComponent(pair)}/ohlcv/minute?aggregate=5&limit=100&currency=usd&token=base${before}`,
      { headers: { Accept: "application/json;version=20230203" }, cache: "no-store" },
    );
    if (!r.ok) return [];
    const body = await r.json() as {data?: {attributes?: {ohlcv_list?: number[][]}}};
    return (body.data?.attributes?.ohlcv_list ?? [])
      .map(row => ({
        timestamp: Number(row[0]) * 1000,
        open: Number(row[1]),
        high: Number(row[2]),
        low: Number(row[3]),
        close: Number(row[4]),
        volume: Number(row[5] ?? 0),
      }))
      .filter(x => Number.isFinite(x.close) && x.close > 0)
      .sort((a,b) => a.timestamp-b.timestamp);
  } catch {
    return [];
  }
}

async function recentCalls() {
  const sql = sqlV4();
  const rows = await sql`SELECT * FROM memescope_call_story LIMIT 60`;
  return (rows as RawRow[]).sort((a,b) => {
    const ta = new Date(String(pick(a,["created_at","detected_at","called_at","signal_time"]) ?? 0)).getTime();
    const tb = new Date(String(pick(b,["created_at","detected_at","called_at","signal_time"]) ?? 0)).getTime();
    return tb-ta;
  });
}

async function historyShare() {
  const settings = await getV4Settings();
  const sql = sqlV4();
  const rows = await sql`
    SELECT content_type, COUNT(*)::INTEGER AS count
    FROM memescope_content_v4_queue
    WHERE created_at >= ${settings.historyResetAt}::timestamptz
      AND status <> 'archived_before_reset'
    GROUP BY content_type
  `;
  const counts = new Map<string, number>();
  let total = 0;
  for (const row of rows) {
    const c = Number(row.count ?? 0);
    counts.set(String(row.content_type), c);
    total += c;
  }
  return { settings, counts, total };
}

async function previouslyPosted(tokenAddress: string) {
  const settings = await getV4Settings();
  const sql = sqlV4();
  const rows = await sql`
    SELECT content_type, created_at
    FROM memescope_content_v4_queue
    WHERE token_address = ${tokenAddress}
      AND created_at >= ${settings.historyResetAt}::timestamptz
      AND status <> 'archived_before_reset'
    ORDER BY created_at DESC
    LIMIT 5
  `;
  return rows as RawRow[];
}

async function saveFirstSnapshot(row: RawRow, token: string, symbol: string, pair: string | null, firstMc: number | null, detectedAt: Date) {
  const sql = sqlV4();
  await sql`
    INSERT INTO memescope_content_v4_snapshots (
      token_address, pair_address, symbol, first_detected_at,
      first_market_cap, source_call_id
    )
    VALUES (
      ${token}, ${pair}, ${symbol}, ${detectedAt.toISOString()}::timestamptz,
      ${firstMc}, ${str(pick(row,["public_id","call_id","id"]))}
    )
    ON CONFLICT (token_address) DO NOTHING
  `;
}

function chooseCaption(type: ContentType, lastTemplate: string | null) {
  const list = CAPTIONS[type];
  const candidates = list.map((text,index) => ({key:`${type}_${String(index+1).padStart(2,"0")}`,text}));
  return candidates.find(c => c.key !== lastTemplate) ?? candidates[0];
}

function nextChartStyle(lastStyle: string | null) {
  const eligible = ["pure_chart","level_setup","first_spotted","minimal_metrics","performance"];
  const index = Math.max(-1, eligible.indexOf(lastStyle ?? ""));
  return eligible[(index + 1) % eligible.length];
}

async function lastUsed() {
  const settings = await getV4Settings();
  const sql = sqlV4();
  const rows = await sql`
    SELECT visual_style, caption_template
    FROM memescope_content_v4_queue
    WHERE created_at >= ${settings.historyResetAt}::timestamptz
      AND status <> 'archived_before_reset'
    ORDER BY created_at DESC
    LIMIT 1
  `;
  return {
    visualStyle: rows.length ? str(rows[0].visual_style) : null,
    captionTemplate: rows.length ? str(rows[0].caption_template) : null,
  };
}

async function buildTokenCandidates(): Promise<Candidate[]> {
  const calls = await recentCalls();
  const last = await lastUsed();
  const result: Candidate[] = [];

  for (const row of calls.slice(0, 12)) {
    const token = str(pick(row,["token_address","mint_address","mint","address","token"]));
    if (!token) continue;

    const symbol = str(pick(row,["symbol","token_symbol","ticker"])) ?? "TOKEN";
    const preferredPair = str(pick(row,["pair_address","pool_address","pair"]));
    const firstMc = num(pick(row,["first_market_cap","call_market_cap","initial_market_cap","market_cap_at_call","market_cap"]));
    const detectedRaw = pick(row,["created_at","detected_at","called_at","signal_time"]);
    const detectedAt = detectedRaw ? new Date(String(detectedRaw)) : new Date();
    const live = await market(token, preferredPair);
    const pair = live.pairAddress ?? preferredPair;
    await saveFirstSnapshot(row, token, symbol, pair, firstMc, detectedAt);

    const currentMc = live.currentMc;
    const multiple = firstMc && currentMc && firstMc > 0 ? currentMc / firstMc : null;
    const candles = await candleSeries(pair);
    if (candles.length < 2) continue;

    const previous = await previouslyPosted(token);
    const hasStory = previous.length > 0;
    const latestAgeMinutes = previous.length
      ? (Date.now() - new Date(String(previous[0].created_at)).getTime()) / 60000
      : Infinity;

    let type: ContentType = hasStory ? "token_update" : "chart_setup";
    let style = nextChartStyle(last.visualStyle);
    let reason = hasStory ? "tracked token developed after an earlier post" : "fresh chart setup from a MemeScope tracked call";
    let branded = false;
    let historicCandles: Candle[] | undefined;

    if (multiple !== null && multiple >= 5) {
      type = "call_journey";
      style = "journey";
      branded = true;
      reason = "tracked call reached a major journey milestone";
    } else if (multiple !== null && multiple >= 2.5) {
      historicCandles = await candleSeries(pair, detectedAt.getTime() + 10 * 60 * 1000);
      if (historicCandles.length >= 2) {
        type = "before_move";
        style = "split_before_now";
        branded = true;
        reason = "move exceeded the existing Before The Move threshold with a real historical chart";
      }
    } else if (hasStory && latestAgeMinutes < 90) {
      continue;
    } else if (hasStory && multiple !== null && multiple < 1.25) {
      continue;
    }

    const cap = chooseCaption(type, last.captionTemplate);
    result.push({
      eventKey: `v4:${type}:${token}:${Math.floor((currentMc ?? 0)/1000)}:${new Date().toISOString().slice(0,13)}`,
      tokenAddress: token,
      pairAddress: pair,
      symbol,
      contentType: type,
      visualStyle: style,
      captionTemplate: cap.key,
      caption: fill(cap.text, symbol, firstMc, currentMc, multiple),
      reason,
      firstMc,
      currentMc,
      multiple,
      liquidity: live.liquidity,
      volume: live.volume,
      branded,
      candles,
      historicCandles,
    });
  }

  return result;
}

async function maybeObservation(): Promise<Candidate | null> {
  const calls = await recentCalls();
  if (!calls.length) return null;
  const last = await lastUsed();
  const active = Math.min(calls.length, 12);
  const quiet = active <= 2;
  const cap = chooseCaption("market_observation", last.captionTemplate);
  const template = quiet ? CAPTIONS.market_observation[2] : cap.text;
  return {
    eventKey: `v4:market_observation:${new Date().toISOString().slice(0,10)}:${quiet?"quiet":"active"}`,
    tokenAddress: null,
    pairAddress: null,
    symbol: "",
    contentType: "market_observation",
    visualStyle: "text_only",
    captionTemplate: quiet ? "market_observation_03" : cap.key,
    caption: template,
    reason: quiet ? "few tracked calls are active" : "tracked market activity is elevated",
    firstMc: null,
    currentMc: null,
    multiple: null,
    liquidity: null,
    volume: null,
    branded: false,
    candles: [],
  };
}

function targetDeficit(type: ContentType, total: number, count: number, target: number) {
  if (total === 0) return target;
  return target - (count / total) * 100;
}

export async function processContentHqV4() {
  await ensureV4Schema();
  const { settings, counts, total } = await historyShare();
  const sql = sqlV4();

  const todayRows = await sql`
    SELECT COUNT(*)::INTEGER AS count
    FROM memescope_content_v4_queue
    WHERE created_at >= date_trunc('day', NOW() AT TIME ZONE 'Asia/Jakarta') AT TIME ZONE 'Asia/Jakarta'
      AND status <> 'archived_before_reset'
  `;
  if (Number(todayRows[0]?.count ?? 0) >= settings.maxPostsPerDay) {
    return { ok: true, created: 0, reason: "daily-limit" };
  }

  const lastRows = await sql`
    SELECT created_at
    FROM memescope_content_v4_queue
    WHERE created_at >= ${settings.historyResetAt}::timestamptz
      AND status <> 'archived_before_reset'
    ORDER BY created_at DESC
    LIMIT 1
  `;
  if (lastRows.length) {
    const gap = (Date.now() - new Date(String(lastRows[0].created_at)).getTime()) / 60000;
    if (gap < settings.minGapMinutes) return { ok: true, created: 0, reason: "minimum-gap" };
  }

  const candidates = await buildTokenCandidates();
  const observation = await maybeObservation();
  if (observation) candidates.push(observation);

  if (!candidates.length) return { ok: true, created: 0, reason: "no-worthy-event" };

  const filtered = candidates.filter(c => {
    if (c.contentType !== "token_watch") return true;
    const share = total ? ((counts.get("token_watch") ?? 0) / total) * 100 : 0;
    return share < settings.tokenWatchPct;
  });

  const ranked = filtered.sort((a,b) => {
    const da = targetDeficit(a.contentType,total,counts.get(a.contentType)??0,settings.mix[a.contentType]??0);
    const db = targetDeficit(b.contentType,total,counts.get(b.contentType)??0,settings.mix[b.contentType]??0);
    const pa = a.contentType === "call_journey" ? 100 :
      a.contentType === "before_move" ? 90 :
      a.contentType === "token_update" ? 75 :
      a.contentType === "chart_setup" ? 65 :
      a.contentType === "token_watch" ? 40 : 25;
    const pb = b.contentType === "call_journey" ? 100 :
      b.contentType === "before_move" ? 90 :
      b.contentType === "token_update" ? 75 :
      b.contentType === "chart_setup" ? 65 :
      b.contentType === "token_watch" ? 40 : 25;
    return (pb + db) - (pa + da);
  });

  const selected = ranked[0];
  const visual = await renderContent({
    symbol: selected.symbol,
    contentType: selected.contentType,
    visualStyle: selected.visualStyle,
    firstMarketCap: selected.firstMc,
    currentMarketCap: selected.currentMc,
    multiple: selected.multiple,
    liquidity: selected.liquidity,
    volume: selected.volume,
    candles: selected.candles,
    historicCandles: selected.historicCandles,
    branded: selected.branded,
  });

  if (selected.contentType !== "market_observation" && !visual) {
    return { ok: true, created: 0, reason: "visual-not-safe-to-publish" };
  }

  const status = settings.manualApproval ? "queued" : "approved";
  try {
    const rows = await sql`
      INSERT INTO memescope_content_v4_queue (
        event_key, token_address, pair_address, symbol,
        content_type, visual_style, caption_template, caption,
        reason, first_market_cap, current_market_cap, multiple,
        image_base64, image_mime, branded, status
      )
      VALUES (
        ${selected.eventKey}, ${selected.tokenAddress}, ${selected.pairAddress}, ${selected.symbol},
        ${selected.contentType}, ${selected.visualStyle}, ${selected.captionTemplate}, ${selected.caption},
        ${selected.reason}, ${selected.firstMc}, ${selected.currentMc}, ${selected.multiple},
        ${visual ? visual.buffer.toString("base64") : null}, ${visual?.mime ?? null},
        ${selected.branded}, ${status}
      )
      RETURNING id, content_type, symbol, visual_style, caption, status
    `;
    return { ok: true, created: 1, item: rows[0] };
  } catch (error) {
    if (String(error).toLowerCase().includes("duplicate")) {
      return { ok: true, created: 0, reason: "duplicate-event" };
    }
    throw error;
  }
}
export async function contentHqV4TestBatch(limit = 6) {
  await ensureV4Schema();
  const sql = sqlV4();
  const candidates = await buildTokenCandidates();
  const observation = await maybeObservation();
  if (observation) candidates.push(observation);

  const unique = new Map<string, Candidate>();
  for (const candidate of candidates) {
    const key = `${candidate.contentType}:${candidate.tokenAddress ?? "text"}`;
    if (!unique.has(key)) unique.set(key, candidate);
  }

  const picked = [...unique.values()].slice(0, Math.max(1, Math.min(limit, 8)));
  const testStyles = [
    "pure_chart",
    "level_setup",
    "first_spotted",
    "minimal_metrics",
    "performance",
  ];
  const created: Array<Record<string, unknown>> = [];

  for (let index = 0; index < picked.length; index++) {
    const selected = picked[index];

    const testStyle =
      selected.contentType === "chart_setup" ||
      selected.contentType === "token_update" ||
      selected.contentType === "token_watch"
        ? testStyles[index % testStyles.length]
        : selected.visualStyle;

    const visual = await renderContent({
      symbol: selected.symbol,
      contentType: selected.contentType,
      visualStyle: testStyle,
      firstMarketCap: selected.firstMc,
      currentMarketCap: selected.currentMc,
      multiple: selected.multiple,
      liquidity: selected.liquidity,
      volume: selected.volume,
      candles: selected.candles,
      historicCandles: selected.historicCandles,
      branded: selected.branded,
    });

    if (selected.contentType !== "market_observation" && !visual) continue;

    const testKey = `v4test:${Date.now()}:${index}:${selected.tokenAddress ?? "text"}`;

    const rows = await sql`
      INSERT INTO memescope_content_v4_queue (
        event_key, token_address, pair_address, symbol,
        content_type, visual_style, caption_template, caption,
        reason, first_market_cap, current_market_cap, multiple,
        image_base64, image_mime, branded, status
      )
      VALUES (
        ${testKey}, ${selected.tokenAddress}, ${selected.pairAddress}, ${selected.symbol},
        ${selected.contentType}, ${testStyle}, ${selected.captionTemplate}, ${selected.caption},
        ${`TEST LAB: ${selected.reason}`}, ${selected.firstMc}, ${selected.currentMc}, ${selected.multiple},
        ${visual ? visual.buffer.toString("base64") : null}, ${visual?.mime ?? null},
        ${selected.branded}, 'queued'
      )
      RETURNING id, content_type, symbol, visual_style, caption, status
    `;

    if (rows.length) created.push(rows[0] as Record<string, unknown>);
  }

  return {
    ok: true,
    requested: limit,
    availableCandidates: candidates.length,
    created: created.length,
    items: created,
  };
}