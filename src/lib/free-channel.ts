import "server-only";

import { createHash } from "node:crypto";

import { neon } from "@neondatabase/serverless";

import {
  escapeTelegramHtml,
  telegramConfig,
  telegramSendMessage,
  telegramSiteUrl,
} from "@/lib/telegram";

type DbRow = Record<string, unknown>;

type PaidSourceKind =
  | "boost"
  | "ad"
  | "profile"
  | "community_takeover";

type PaidCandidate = {
  eventKey: string;
  tokenAddress: string;
  sourceKind: PaidSourceKind;
  sourceLabel: string;
  sourceAt: number | null;
  dexUrl: string | null;
};

type MarketSnapshot = {
  tokenAddress: string;
  symbol: string;
  name: string;
  marketCapUsd: number | null;
  liquidityUsd: number | null;
  volume24hUsd: number | null;
  dexUrl: string | null;
};

type VipResultRow = {
  signalRecordId: string;
  publicId: string;
  tokenAddress: string;
  symbol: string;
  name: string;
  callMarketCapUsd: number | null;
  peakMarketCapUsd: number | null;
  peakMultiple: number;
};

type SourceResult = {
  ok: boolean;
  candidates: PaidCandidate[];
};

type PaidOrder = {
  type: string;
  status: string;
  paymentTimestamp: number | null;
};

const DEX_API = "https://api.dexscreener.com";
const FREE_RESULT_MILESTONES = [3, 5, 10, 20, 50, 100] as const;

let schemaPromise: Promise<void> | null = null;

function sqlClient() {
  const databaseUrl = process.env.DATABASE_URL?.trim();

  if (!databaseUrl) {
    throw new Error("DATABASE_URL is not configured.");
  }

  return neon(databaseUrl);
}

function freeChannelConfig() {
  const telegram = telegramConfig();

  return {
    botConfigured: Boolean(telegram.botToken),
    vipChannelId: telegram.channelId,
    vipJoinUrl:
      process.env.TELEGRAM_VIP_JOIN_URL?.trim() ||
      telegram.channelUrl ||
      "",
    freeChannelId:
      process.env.TELEGRAM_FREE_CHANNEL_ID?.trim() ?? "",
    freeChannelUrl:
      process.env.TELEGRAM_FREE_CHANNEL_URL?.trim() ?? "",
  };
}

export function freeChannelConfigured() {
  const config = freeChannelConfig();

  return Boolean(
    config.botConfigured &&
      config.freeChannelId &&
      config.freeChannelId !== config.vipChannelId,
  );
}

function numOrNull(value: unknown): number | null {
  if (value === null || value === undefined || value === "") {
    return null;
  }

  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function stringOrNull(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

function objectValue(value: unknown): Record<string, unknown> | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return null;
  }

  return value as Record<string, unknown>;
}

function objectArray(value: unknown): Array<Record<string, unknown>> {
  if (Array.isArray(value)) {
    return value
      .map((item) => objectValue(item))
      .filter((item): item is Record<string, unknown> => item !== null);
  }

  const one = objectValue(value);
  return one ? [one] : [];
}

function millisFromUnknown(value: unknown): number | null {
  const numeric = numOrNull(value);

  if (numeric !== null) {
    // DEX Screener order timestamps may be seconds or milliseconds.
    if (numeric > 0 && numeric < 10_000_000_000) {
      return numeric * 1_000;
    }

    return numeric > 0 ? numeric : null;
  }

  const text = stringOrNull(value);
  if (!text) return null;

  const parsed = Date.parse(text);
  return Number.isFinite(parsed) ? parsed : null;
}

function compactUsd(value: number | null) {
  if (value === null || !Number.isFinite(value)) return "N/A";

  const absolute = Math.abs(value);

  if (absolute >= 1_000_000_000) {
    return `$${(value / 1_000_000_000).toFixed(2)}B`;
  }

  if (absolute >= 1_000_000) {
    return `$${(value / 1_000_000).toFixed(2)}M`;
  }

  if (absolute >= 1_000) {
    return `$${(value / 1_000).toFixed(1)}K`;
  }

  return `$${value.toFixed(0)}`;
}

function multipleText(value: number) {
  return `${value.toFixed(value >= 10 ? 1 : 2)}X`;
}

function cleanLabel(value: string) {
  return value
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .toUpperCase();
}

function hash(value: string) {
  return createHash("sha256").update(value).digest("hex").slice(0, 24);
}

async function fetchJson(url: string): Promise<unknown> {
  const response = await fetch(url, {
    cache: "no-store",
    headers: {
      accept: "application/json",
    },
    signal: AbortSignal.timeout(8_000),
  });

  if (!response.ok) {
    throw new Error(`DEX Screener request failed (${response.status}).`);
  }

  return response.json();
}

function solanaRows(value: unknown) {
  return objectArray(value).filter(
    (row) => String(row.chainId ?? "").toLowerCase() === "solana",
  );
}

async function fetchBoostCandidates(): Promise<SourceResult> {
  try {
    const body = await fetchJson(`${DEX_API}/token-boosts/latest/v1`);
    const candidates = solanaRows(body)
      .map((row): PaidCandidate | null => {
        const tokenAddress = stringOrNull(row.tokenAddress);
        if (!tokenAddress) return null;

        const amount = numOrNull(row.amount) ?? 0;
        const totalAmount = numOrNull(row.totalAmount) ?? amount;
        const dexUrl = stringOrNull(row.url);

        return {
          eventKey: `boost:${tokenAddress}:${totalAmount}:${amount}`,
          tokenAddress,
          sourceKind: "boost",
          sourceLabel: "DEX BOOST",
          sourceAt: null,
          dexUrl,
        };
      })
      .filter((item): item is PaidCandidate => item !== null);

    return { ok: true, candidates };
  } catch (error) {
    console.error("MemeScope FREE boost source failed:", error);
    return { ok: false, candidates: [] };
  }
}

async function fetchAdCandidates(): Promise<SourceResult> {
  try {
    const body = await fetchJson(`${DEX_API}/ads/latest/v1`);
    const candidates = solanaRows(body)
      .map((row): PaidCandidate | null => {
        const tokenAddress = stringOrNull(row.tokenAddress);
        if (!tokenAddress) return null;

        const dateText = stringOrNull(row.date) ?? "unknown";
        const type = stringOrNull(row.type) ?? "tokenAd";
        const dexUrl = stringOrNull(row.url);

        return {
          eventKey: `ad:${tokenAddress}:${type}:${dateText}`,
          tokenAddress,
          sourceKind: "ad",
          sourceLabel: type.toLowerCase().includes("trending")
            ? "TRENDING BAR AD"
            : "DEX AD",
          sourceAt: millisFromUnknown(dateText),
          dexUrl,
        };
      })
      .filter((item): item is PaidCandidate => item !== null);

    return { ok: true, candidates };
  } catch (error) {
    console.error("MemeScope FREE ad source failed:", error);
    return { ok: false, candidates: [] };
  }
}

async function fetchCommunityTakeoverCandidates(): Promise<SourceResult> {
  try {
    const body = await fetchJson(`${DEX_API}/community-takeovers/latest/v1`);
    const candidates = solanaRows(body)
      .map((row): PaidCandidate | null => {
        const tokenAddress = stringOrNull(row.tokenAddress);
        if (!tokenAddress) return null;

        const claimDate = stringOrNull(row.claimDate) ?? "unknown";
        const dexUrl = stringOrNull(row.url);

        return {
          eventKey: `cto:${tokenAddress}:${claimDate}`,
          tokenAddress,
          sourceKind: "community_takeover",
          sourceLabel: "COMMUNITY TAKEOVER",
          sourceAt: millisFromUnknown(claimDate),
          dexUrl,
        };
      })
      .filter((item): item is PaidCandidate => item !== null);

    return { ok: true, candidates };
  } catch (error) {
    console.error("MemeScope FREE CTO source failed:", error);
    return { ok: false, candidates: [] };
  }
}

function paidOrders(value: unknown): PaidOrder[] {
  const top = objectValue(value);
  const rawOrders = top && Array.isArray(top.orders) ? top.orders : value;

  return objectArray(rawOrders)
    .map((row): PaidOrder | null => {
      const type = stringOrNull(row.type);
      const status = stringOrNull(row.status);

      if (!type || !status) return null;

      return {
        type,
        status,
        paymentTimestamp: millisFromUnknown(row.paymentTimestamp),
      };
    })
    .filter((item): item is PaidOrder => item !== null);
}

function validPaidOrder(order: PaidOrder) {
  return (
    order.paymentTimestamp !== null &&
    (order.status === "approved" ||
      order.status === "processing" ||
      order.status === "on-hold")
  );
}

async function fetchProfileOrderCandidate(
  row: Record<string, unknown>,
): Promise<PaidCandidate | null> {
  const tokenAddress = stringOrNull(row.tokenAddress);
  if (!tokenAddress) return null;

  try {
    const body = await fetchJson(
      `${DEX_API}/orders/v1/solana/${encodeURIComponent(tokenAddress)}`,
    );

    const profileOrders = paidOrders(body)
      .filter(
        (order) => order.type === "tokenProfile" && validPaidOrder(order),
      )
      .sort(
        (a, b) =>
          (b.paymentTimestamp ?? 0) - (a.paymentTimestamp ?? 0),
      );

    const order = profileOrders[0];
    if (!order || order.paymentTimestamp === null) return null;

    return {
      eventKey: `profile:${tokenAddress}:${order.paymentTimestamp}`,
      tokenAddress,
      sourceKind: "profile",
      sourceLabel: "TOKEN PROFILE",
      sourceAt: order.paymentTimestamp,
      dexUrl: stringOrNull(row.url),
    };
  } catch {
    return null;
  }
}

async function fetchProfileCandidates(): Promise<SourceResult> {
  try {
    const body = await fetchJson(`${DEX_API}/token-profiles/latest/v1`);
    const rows = solanaRows(body).slice(0, 30);
    const candidates: PaidCandidate[] = [];

    // Limit concurrency to stay comfortably inside the 60 rpm paid-order limit.
    for (let index = 0; index < rows.length; index += 5) {
      const batch = rows.slice(index, index + 5);
      const checked = await Promise.all(batch.map(fetchProfileOrderCandidate));

      for (const candidate of checked) {
        if (candidate) candidates.push(candidate);
      }
    }

    return { ok: true, candidates };
  } catch (error) {
    console.error("MemeScope FREE profile source failed:", error);
    return { ok: false, candidates: [] };
  }
}

async function discoverPaidCandidates() {
  const results = await Promise.all([
    fetchBoostCandidates(),
    fetchAdCandidates(),
    fetchCommunityTakeoverCandidates(),
    fetchProfileCandidates(),
  ]);

  const map = new Map<string, PaidCandidate>();

  for (const result of results) {
    for (const candidate of result.candidates) {
      map.set(candidate.eventKey, candidate);
    }
  }

  return {
    successfulSources: results.filter((result) => result.ok).length,
    candidates: Array.from(map.values()),
  };
}

async function fetchMarketSnapshots(addresses: string[]) {
  const unique = Array.from(new Set(addresses.filter(Boolean)));
  const result = new Map<string, MarketSnapshot>();
  const liquidityByAddress = new Map<string, number>();

  for (let index = 0; index < unique.length; index += 30) {
    const batch = unique.slice(index, index + 30);
    if (batch.length === 0) continue;

    try {
      const body = await fetchJson(
        `${DEX_API}/tokens/v1/solana/${batch.map(encodeURIComponent).join(",")}`,
      );

      for (const pair of objectArray(body)) {
        const baseToken = objectValue(pair.baseToken);
        const address = stringOrNull(baseToken?.address);
        if (!address || !unique.includes(address)) continue;

        const liquidity = objectValue(pair.liquidity);
        const volume = objectValue(pair.volume);
        const liquidityUsd = numOrNull(liquidity?.usd);
        const previousLiquidity = liquidityByAddress.get(address) ?? -1;
        const rankingLiquidity = liquidityUsd ?? 0;

        if (rankingLiquidity < previousLiquidity) continue;

        const marketCapUsd =
          numOrNull(pair.marketCap) ?? numOrNull(pair.fdv);

        result.set(address, {
          tokenAddress: address,
          symbol: stringOrNull(baseToken?.symbol) ?? "TOKEN",
          name: stringOrNull(baseToken?.name) ?? "Unknown Token",
          marketCapUsd,
          liquidityUsd,
          volume24hUsd: numOrNull(volume?.h24),
          dexUrl:
            stringOrNull(pair.url) ??
            `https://dexscreener.com/solana/${encodeURIComponent(address)}`,
        });

        liquidityByAddress.set(address, rankingLiquidity);
      }
    } catch (error) {
      console.error("MemeScope FREE market enrichment failed:", error);
    }
  }

  return result;
}

function freeButtons(dexUrl: string | null) {
  const config = freeChannelConfig();
  const firstRow: Array<{ text: string; url: string }> = [];

  if (dexUrl) {
    firstRow.push({
      text: "📊 DexScreener",
      url: dexUrl,
    });
  }

  if (config.vipJoinUrl) {
    firstRow.push({
      text: "🔒 VIP",
      url: config.vipJoinUrl,
    });
  }

  const rows: Array<Array<{ text: string; url: string }>> = [];

  if (firstRow.length > 0) {
    rows.push(firstRow);
  }

  rows.push([
    {
      text: "🌐 MemeScope",
      url: telegramSiteUrl(),
    },
  ]);

  return {
    inline_keyboard: rows,
  };
}

function paidAlertText(
  market: MarketSnapshot,
  candidates: PaidCandidate[],
) {
  const labels = Array.from(
    new Set(candidates.map((candidate) => cleanLabel(candidate.sourceLabel))),
  );

  return [
    "⚡ <b>MEMESCOPE DEX WATCH</b>",
    "",
    "🟠 <b>PAID ACTIVITY DETECTED</b>",
    "",
    `<b>$${escapeTelegramHtml(market.symbol)}</b> | ${escapeTelegramHtml(market.name)}`,
    "",
    "╭─ <b>MARKET SNAPSHOT</b>",
    `├ 💰 Market Cap <b>${compactUsd(market.marketCapUsd)}</b>`,
    `├ 💧 Liquidity <b>${compactUsd(market.liquidityUsd)}</b>`,
    `├ 📊 Volume 24h <b>${compactUsd(market.volume24hUsd)}</b>`,
    `╰ 🧾 DEX Activity <b>${escapeTelegramHtml(labels.join(" + "))}</b>`,
    "",
    "📋 <b>Contract</b>",
    `<code>${escapeTelegramHtml(market.tokenAddress)}</code>`,
    "",
    "⚠️ <i>Paid DEX activity detected. This is market activity, not a MemeScope VIP signal.</i>",
    "",
    "🔒 <b>VIP sees the calls before selected results.</b>",
    "",
    "<b>MemeScope</b>",
  ].join("\n");
}

function highestFreeResultMilestone(value: number) {
  let result = 0;

  for (const milestone of FREE_RESULT_MILESTONES) {
    if (value >= milestone) result = milestone;
  }

  return result;
}

function vipResultTitle(milestone: number) {
  if (milestone >= 20) return "💎 MEMESCOPE VIP RUNNER";
  if (milestone >= 10) return "🏆 MEMESCOPE VIP RUNNER";
  return "🔥 MEMESCOPE VIP RESULT";
}

function vipResultText(call: VipResultRow) {
  return [
    `<b>${vipResultTitle(highestFreeResultMilestone(call.peakMultiple))}</b>`,
    "",
    `<b>$${escapeTelegramHtml(call.symbol)} • ${multipleText(call.peakMultiple)} FROM VIP CALL</b>`,
    "",
    "╭─ <b>TRACKED PERFORMANCE</b>",
    `├ 🎯 VIP Call MC <b>${compactUsd(call.callMarketCapUsd)}</b>`,
    `├ 🚀 Peak MC <b>${compactUsd(call.peakMarketCapUsd)}</b>`,
    `├ 📈 Peak Multiple <b>${multipleText(call.peakMultiple)}</b>`,
    "╰ ✅ Tracked from the original VIP call",
    "",
    "This result comes from a timestamped MemeScope VIP call. The original live entry is not being republished here.",
    "",
    "🔒 <b>VIP sees the call. Public sees selected results.</b>",
    "",
    "<b>MemeScope</b>",
  ].join("\n");
}

export async function ensureFreeChannelSchema() {
  if (schemaPromise) return schemaPromise;

  schemaPromise = (async () => {
    const sql = sqlClient();

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_free_channel_state (
        id INTEGER PRIMARY KEY,
        dex_initialized_at TIMESTAMPTZ,
        vip_initialized_at TIMESTAMPTZ,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      INSERT INTO memescope_free_channel_state (id)
      VALUES (1)
      ON CONFLICT (id) DO NOTHING
    `;

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_free_dex_events (
        event_key TEXT PRIMARY KEY,
        token_address TEXT NOT NULL,
        source_kind TEXT NOT NULL,
        source_label TEXT NOT NULL,
        source_at TIMESTAMPTZ,
        baseline BOOLEAN NOT NULL DEFAULT FALSE,
        free_post_key TEXT,
        seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      CREATE INDEX IF NOT EXISTS memescope_free_dex_token_idx
      ON memescope_free_dex_events (token_address, seen_at DESC)
    `;

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_free_posts (
        post_key TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        token_address TEXT,
        signal_record_id TEXT,
        milestone DOUBLE PRECISION,
        baseline BOOLEAN NOT NULL DEFAULT FALSE,
        telegram_message_id BIGINT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        posted_at TIMESTAMPTZ
      )
    `;

    await sql`
      CREATE INDEX IF NOT EXISTS memescope_free_posts_signal_idx
      ON memescope_free_posts (signal_record_id, milestone DESC)
    `;
  })().catch((error) => {
    schemaPromise = null;
    throw error;
  });

  return schemaPromise;
}

async function baselineDexPaidEvents() {
  const sql = sqlClient();

  const stateRows = await sql`
    SELECT dex_initialized_at
    FROM memescope_free_channel_state
    WHERE id = 1
    LIMIT 1
  `;

  if ((stateRows[0] as DbRow | undefined)?.dex_initialized_at) {
    return { initialized: false, baselineCount: 0 };
  }

  const discovered = await discoverPaidCandidates();

  if (discovered.successfulSources === 0) {
    return { initialized: false, baselineCount: 0 };
  }

  let baselineCount = 0;

  for (const candidate of discovered.candidates) {
    await sql`
      INSERT INTO memescope_free_dex_events (
        event_key,
        token_address,
        source_kind,
        source_label,
        source_at,
        baseline
      ) VALUES (
        ${candidate.eventKey},
        ${candidate.tokenAddress},
        ${candidate.sourceKind},
        ${candidate.sourceLabel},
        ${candidate.sourceAt === null ? null : new Date(candidate.sourceAt).toISOString()},
        TRUE
      )
      ON CONFLICT (event_key) DO NOTHING
    `;

    baselineCount += 1;
  }

  await sql`
    UPDATE memescope_free_channel_state
    SET dex_initialized_at = NOW(), updated_at = NOW()
    WHERE id = 1
  `;

  return { initialized: true, baselineCount };
}

async function currentVipResults(): Promise<VipResultRow[]> {
  const sql = sqlClient();

  const rows = await sql`
    SELECT
      c.signal_record_id,
      c.public_id,
      c.token_address,
      c.symbol,
      c.name,
      c.call_market_cap_usd,
      c.peak_market_cap_usd,
      c.peak_multiple
    FROM memescope_call_story c
    INNER JOIN memescope_telegram_posts p
      ON p.signal_record_id = c.signal_record_id
    WHERE c.baseline = FALSE
      AND p.message_id IS NOT NULL
      AND COALESCE(c.peak_multiple, 1) >= 3
    ORDER BY c.called_at ASC
    LIMIT 500
  `;

  return rows
    .map((raw): VipResultRow | null => {
      const row = raw as DbRow;
      const peakMultiple = numOrNull(row.peak_multiple);

      if (peakMultiple === null || peakMultiple < 3) return null;

      return {
        signalRecordId: String(row.signal_record_id),
        publicId: String(row.public_id ?? ""),
        tokenAddress: String(row.token_address),
        symbol: String(row.symbol),
        name: String(row.name),
        callMarketCapUsd: numOrNull(row.call_market_cap_usd),
        peakMarketCapUsd: numOrNull(row.peak_market_cap_usd),
        peakMultiple,
      };
    })
    .filter((item): item is VipResultRow => item !== null);
}

async function baselineVipResults() {
  const sql = sqlClient();

  const stateRows = await sql`
    SELECT vip_initialized_at
    FROM memescope_free_channel_state
    WHERE id = 1
    LIMIT 1
  `;

  if ((stateRows[0] as DbRow | undefined)?.vip_initialized_at) {
    return { initialized: false, baselineCount: 0 };
  }

  const calls = await currentVipResults();
  let baselineCount = 0;

  for (const call of calls) {
    const milestone = highestFreeResultMilestone(call.peakMultiple);
    if (milestone === 0) continue;

    await sql`
      INSERT INTO memescope_free_posts (
        post_key,
        kind,
        token_address,
        signal_record_id,
        milestone,
        baseline
      ) VALUES (
        ${`vip:${call.signalRecordId}:${milestone}`},
        'vip_result',
        ${call.tokenAddress},
        ${call.signalRecordId},
        ${milestone},
        TRUE
      )
      ON CONFLICT (post_key) DO NOTHING
    `;

    baselineCount += 1;
  }

  await sql`
    UPDATE memescope_free_channel_state
    SET vip_initialized_at = NOW(), updated_at = NOW()
    WHERE id = 1
  `;

  return { initialized: true, baselineCount };
}

async function publishDexPaidAlerts() {
  const sql = sqlClient();
  const config = freeChannelConfig();
  const discovered = await discoverPaidCandidates();

  if (discovered.successfulSources === 0) {
    return { sent: 0, discovered: 0 };
  }

  const seenRows = await sql`
    SELECT event_key
    FROM memescope_free_dex_events
    ORDER BY seen_at DESC
    LIMIT 10000
  `;

  const seen = new Set(seenRows.map((row: unknown) => String((row as DbRow).event_key)));
  const unseen = discovered.candidates.filter((candidate) => !seen.has(candidate.eventKey));

  const grouped = new Map<string, PaidCandidate[]>();

  for (const candidate of unseen) {
    const list = grouped.get(candidate.tokenAddress) ?? [];
    list.push(candidate);
    grouped.set(candidate.tokenAddress, list);
  }

  const groups = Array.from(grouped.entries())
    .sort((a, b) => {
      const aAt = Math.max(...a[1].map((item) => item.sourceAt ?? 0));
      const bAt = Math.max(...b[1].map((item) => item.sourceAt ?? 0));
      return bAt - aAt;
    })
    .slice(0, Math.max(1, Math.min(10, Number(process.env.MEMESCOPE_FREE_DEX_MAX_PER_CYCLE ?? 6) || 6)));

  if (groups.length === 0) {
    return { sent: 0, discovered: discovered.candidates.length };
  }

  const markets = await fetchMarketSnapshots(groups.map(([address]) => address));
  let sent = 0;

  for (const [tokenAddress, candidates] of groups) {
    const market = markets.get(tokenAddress);

    // Fresh paid activity can appear before the token has a live indexed pool.
    // Keep it unseen so a later cycle can retry once market data exists.
    if (!market) continue;

    const signature = candidates
      .map((candidate) => candidate.eventKey)
      .sort()
      .join("|");

    const postKey = `dex:${tokenAddress}:${hash(signature)}`;

    const reserved = await sql`
      INSERT INTO memescope_free_posts (
        post_key,
        kind,
        token_address,
        baseline
      ) VALUES (
        ${postKey},
        'dex_paid',
        ${tokenAddress},
        FALSE
      )
      ON CONFLICT (post_key) DO NOTHING
      RETURNING post_key
    `;

    if (!reserved[0]) continue;

    try {
      const dexUrl =
        market.dexUrl ??
        candidates.find((candidate) => candidate.dexUrl)?.dexUrl ??
        null;

      const message = await telegramSendMessage(
        config.freeChannelId,
        paidAlertText(market, candidates),
        {
          replyMarkup: freeButtons(dexUrl),
        },
      );

      for (const candidate of candidates) {
        await sql`
          INSERT INTO memescope_free_dex_events (
            event_key,
            token_address,
            source_kind,
            source_label,
            source_at,
            baseline,
            free_post_key
          ) VALUES (
            ${candidate.eventKey},
            ${candidate.tokenAddress},
            ${candidate.sourceKind},
            ${candidate.sourceLabel},
            ${candidate.sourceAt === null ? null : new Date(candidate.sourceAt).toISOString()},
            FALSE,
            ${postKey}
          )
          ON CONFLICT (event_key) DO NOTHING
        `;
      }

      await sql`
        UPDATE memescope_free_posts
        SET telegram_message_id = ${message.message_id}, posted_at = NOW()
        WHERE post_key = ${postKey}
      `;

      sent += 1;
    } catch (error) {
      await sql`
        DELETE FROM memescope_free_posts
        WHERE post_key = ${postKey}
          AND posted_at IS NULL
      `;

      console.error("MemeScope FREE paid alert publish failed:", error);
    }
  }

  return {
    sent,
    discovered: discovered.candidates.length,
  };
}

async function publishVipResults() {
  const sql = sqlClient();
  const config = freeChannelConfig();
  const calls = await currentVipResults();
  let sent = 0;

  for (const call of calls) {
    const milestone = highestFreeResultMilestone(call.peakMultiple);
    if (milestone === 0) continue;

    const postKey = `vip:${call.signalRecordId}:${milestone}`;

    const reserved = await sql`
      INSERT INTO memescope_free_posts (
        post_key,
        kind,
        token_address,
        signal_record_id,
        milestone,
        baseline
      ) VALUES (
        ${postKey},
        'vip_result',
        ${call.tokenAddress},
        ${call.signalRecordId},
        ${milestone},
        FALSE
      )
      ON CONFLICT (post_key) DO NOTHING
      RETURNING post_key
    `;

    if (!reserved[0]) continue;

    try {
      const message = await telegramSendMessage(
        config.freeChannelId,
        vipResultText(call),
        {
          replyMarkup: freeButtons(null),
        },
      );

      await sql`
        UPDATE memescope_free_posts
        SET telegram_message_id = ${message.message_id}, posted_at = NOW()
        WHERE post_key = ${postKey}
      `;

      sent += 1;
    } catch (error) {
      await sql`
        DELETE FROM memescope_free_posts
        WHERE post_key = ${postKey}
          AND posted_at IS NULL
      `;

      console.error("MemeScope FREE VIP result publish failed:", error);
    }
  }

  return { sent };
}

export async function runFreeChannelCycle() {
  if (!freeChannelConfigured()) {
    return {
      configured: false,
      initialized: false,
      dexPaidSent: 0,
      vipResultsSent: 0,
    };
  }

  await ensureFreeChannelSchema();

  const dexBaseline = await baselineDexPaidEvents();
  const vipBaseline = await baselineVipResults();

  const dex = dexBaseline.initialized
    ? { sent: 0, discovered: dexBaseline.baselineCount }
    : await publishDexPaidAlerts();

  const vip = vipBaseline.initialized
    ? { sent: 0 }
    : await publishVipResults();

  return {
    configured: true,
    initialized: dexBaseline.initialized || vipBaseline.initialized,
    dexBaselineCount: dexBaseline.baselineCount,
    vipBaselineCount: vipBaseline.baselineCount,
    dexPaidSent: dex.sent,
    vipResultsSent: vip.sent,
  };
}

export async function sendFreeChannelTest(kind: "dex" | "vip") {
  if (!freeChannelConfigured()) {
    throw new Error(
      "TELEGRAM_FREE_CHANNEL_ID is missing, the Telegram bot is not configured, or FREE and VIP channel IDs are identical.",
    );
  }

  const config = freeChannelConfig();

  if (kind === "vip") {
    const sample: VipResultRow = {
      signalRecordId: "TEST",
      publicId: "MS-TEST-001",
      tokenAddress: "TEST_FREE_CHANNEL",
      symbol: "MSCOPE",
      name: "MemeScope Test",
      callMarketCapUsd: 84_000,
      peakMarketCapUsd: 287_000,
      peakMultiple: 3.42,
    };

    return telegramSendMessage(
      config.freeChannelId,
      [
        vipResultText(sample),
        "",
        "⚠️ <i>Formatting test only.</i>",
      ].join("\n"),
      {
        replyMarkup: freeButtons(null),
      },
    );
  }

  const market: MarketSnapshot = {
    tokenAddress: "TEST_FREE_CHANNEL",
    symbol: "MSCOPE",
    name: "MemeScope Test",
    marketCapUsd: 196_900,
    liquidityUsd: 39_600,
    volume24hUsd: 407_300,
    dexUrl: null,
  };

  const candidate: PaidCandidate = {
    eventKey: "test",
    tokenAddress: market.tokenAddress,
    sourceKind: "boost",
    sourceLabel: "DEX BOOST",
    sourceAt: Date.now(),
    dexUrl: null,
  };

  return telegramSendMessage(
    config.freeChannelId,
    [
      paidAlertText(market, [candidate]),
      "",
      "⚠️ <i>Formatting test only.</i>",
    ].join("\n"),
    {
      replyMarkup: freeButtons(null),
    },
  );
}
