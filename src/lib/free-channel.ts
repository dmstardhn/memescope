import "server-only";
import { getFreeChannelPostKeyboard } from "@/lib/free-buttons";
import { renderSignalResultCard } from "@/lib/signal-result-card";

import { createHash } from "node:crypto";

import { neon } from "@neondatabase/serverless";
import sharp from "sharp";

import {
  escapeTelegramHtml,
  telegramConfig,
  telegramSendMessage,
  telegramSendPhoto,
  telegramSendPhotoUpload,
  telegramSiteUrl,
} from "@/lib/telegram";

// MEMESCOPE FREE BUTTON WRAPPER
// Existing per-post system buttons (for example token-specific DexScreener links)
// are preserved. Admin-managed custom buttons are appended underneath them.
async function freeChannelSendMessage(
  chatId: Parameters<typeof telegramSendMessage>[0],
  text: Parameters<typeof telegramSendMessage>[1],
  options?: Parameters<typeof telegramSendMessage>[2],
) {
  const customKeyboard =
    await getFreeChannelPostKeyboard();

  const existingReplyMarkup =
    options?.replyMarkup as
      | {
          inline_keyboard?: Array<
            Array<{
              text: string;
              url?: string;
              callback_data?: string;
            }>
          >;
        }
      | undefined;

  const systemRows =
    Array.isArray(
      existingReplyMarkup
        ?.inline_keyboard,
    )
      ? existingReplyMarkup
          .inline_keyboard
      : [];

  const customRows =
    Array.isArray(
      customKeyboard
        ?.inline_keyboard,
    )
      ? customKeyboard
          .inline_keyboard
      : [];

  const mergedKeyboard =
    systemRows.length > 0 ||
    customRows.length > 0
      ? {
          inline_keyboard: [
            ...systemRows,
            ...customRows,
          ],
        }
      : undefined;

  const nextOptions = {
    ...(options ?? {}),
    ...(mergedKeyboard
      ? {
          replyMarkup:
            mergedKeyboard,
        }
      : {}),
  } as Parameters<
    typeof telegramSendMessage
  >[2];

  return telegramSendMessage(
    chatId,
    text,
    nextOptions,
  );
}

async function prepareFreeChannelPhoto(
  photoUrl: string,
) {
  const response =
    await fetch(photoUrl, {
      cache: "no-store",
      signal:
        AbortSignal.timeout(
          10_000,
        ),
    });

  if (!response.ok) {
    throw new Error(
      `Token media download failed (${response.status}).`,
    );
  }

  const input =
    Buffer.from(
      await response.arrayBuffer(),
    );

  const output =
    await sharp(input)
      .rotate()
      .resize(1500, 500, {
        fit: "cover",
        position: "attention",
      })
      .jpeg({
        quality: 90,
        mozjpeg: true,
      })
      .toBuffer();

  return new Blob(
    [new Uint8Array(output)],
    {
      type: "image/jpeg",
    },
  );
}

async function freeChannelSendPhotoMessage(
  chatId: Parameters<typeof telegramSendPhoto>[0],
  photo: Parameters<typeof telegramSendPhoto>[1],
  caption: string,
  options?: Omit<
    NonNullable<
      Parameters<typeof telegramSendPhoto>[2]
    >,
    "caption"
  >,
) {
  const customKeyboard =
    await getFreeChannelPostKeyboard();

  const existingReplyMarkup =
    options?.replyMarkup as
      | {
          inline_keyboard?: Array<
            Array<{
              text: string;
              url?: string;
              callback_data?: string;
            }>
          >;
        }
      | undefined;

  const systemRows =
    Array.isArray(
      existingReplyMarkup
        ?.inline_keyboard,
    )
      ? existingReplyMarkup
          .inline_keyboard
      : [];

  const customRows =
    Array.isArray(
      customKeyboard
        ?.inline_keyboard,
    )
      ? customKeyboard
          .inline_keyboard
      : [];

  const mergedKeyboard =
    systemRows.length > 0 ||
    customRows.length > 0
      ? {
          inline_keyboard: [
            ...systemRows,
            ...customRows,
          ],
        }
      : undefined;

  const nextOptions = {
    ...(options ?? {}),
    caption,
    ...(mergedKeyboard
      ? {
          replyMarkup:
            mergedKeyboard,
        }
      : {}),
  } as Parameters<
    typeof telegramSendPhoto
  >[2];

  try {
    const cropped =
      await prepareFreeChannelPhoto(
        photo,
      );

    return await telegramSendPhotoUpload(
      chatId,
      cropped,
      nextOptions,
    );
  } catch (error) {
    console.error(
      "MemeScope FREE image crop/upload failed, using original media:",
      error,
    );
  }

  try {
    return await telegramSendPhoto(
      chatId,
      photo,
      nextOptions,
    );
  } catch (error) {
    console.error(
      "MemeScope FREE original media failed, using text fallback:",
      error,
    );

    return freeChannelSendMessage(
      chatId,
      caption,
      {
        replyMarkup:
          mergedKeyboard,
      },
    );
  }
}

async function freeChannelSendResultCardMessage(
  chatId: Parameters<typeof telegramSendPhotoUpload>[0],
  photo: Blob,
  caption: string,
  options?: Omit<
    NonNullable<Parameters<typeof telegramSendPhoto>[2]>,
    "caption"
  >,
) {
  const customKeyboard =
    await getFreeChannelPostKeyboard();

  const existingReplyMarkup =
    options?.replyMarkup as
      | {
          inline_keyboard?: Array<
            Array<{
              text: string;
              url?: string;
              callback_data?: string;
            }>
          >;
        }
      | undefined;

  const systemRows =
    Array.isArray(
      existingReplyMarkup
        ?.inline_keyboard,
    )
      ? existingReplyMarkup
          .inline_keyboard
      : [];

  const customRows =
    Array.isArray(
      customKeyboard
        ?.inline_keyboard,
    )
      ? customKeyboard
          .inline_keyboard
      : [];

  const mergedKeyboard =
    systemRows.length > 0 ||
    customRows.length > 0
      ? {
          inline_keyboard: [
            ...systemRows,
            ...customRows,
          ],
        }
      : undefined;

  return telegramSendPhotoUpload(
    chatId,
    photo,
    {
      ...(options ?? {}),
      caption,
      ...(mergedKeyboard
        ? {
            replyMarkup:
              mergedKeyboard,
          }
        : {}),
    },
  );
}


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
  imageUrl: string | null;
  bannerUrl: string | null;
};

type VipResultRow = {
  signalRecordId: string;
  publicId: string;
  tokenAddress: string;
  symbol: string;
  name: string;
  calledAt: number;
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


export type FreeChannelAdminSettings = {
  configured: boolean;
  enabled: boolean;
  dexEnabled: boolean;
  vipResultsEnabled: boolean;
  minVipResultMultiple: 3 | 5 | 10;
};

function normalizeFreeMinResult(value: unknown): 3 | 5 | 10 {
  const n = Number(value);
  if (n >= 10) return 10;
  if (n >= 5) return 5;
  return 3;
}

export async function getFreeChannelAdminSettings(): Promise<FreeChannelAdminSettings> {
  await ensureFreeChannelSchema();

  const sql = sqlClient();
  const rows = await sql`
    SELECT
      enabled,
      dex_enabled,
      vip_results_enabled,
      min_vip_result_multiple
    FROM memescope_free_channel_state
    WHERE id = 1
    LIMIT 1
  `;

  const row = (rows[0] ?? {}) as DbRow;

  return {
    configured: freeChannelConfigured(),
    enabled: row.enabled !== false,
    dexEnabled: row.dex_enabled !== false,
    vipResultsEnabled: row.vip_results_enabled !== false,
    minVipResultMultiple: normalizeFreeMinResult(row.min_vip_result_multiple),
  };
}

export async function updateFreeChannelAdminSettings(
  patch: Partial<Pick<
    FreeChannelAdminSettings,
    "enabled" | "dexEnabled" | "vipResultsEnabled" | "minVipResultMultiple"
  >>,
): Promise<FreeChannelAdminSettings> {
  await ensureFreeChannelSchema();

  const current = await getFreeChannelAdminSettings();
  const enabled = patch.enabled ?? current.enabled;
  const dexEnabled = patch.dexEnabled ?? current.dexEnabled;
  const vipResultsEnabled =
    patch.vipResultsEnabled ?? current.vipResultsEnabled;
  const minVipResultMultiple = normalizeFreeMinResult(
    patch.minVipResultMultiple ?? current.minVipResultMultiple,
  );

  const sql = sqlClient();
  await sql`
    UPDATE memescope_free_channel_state
    SET
      enabled = ${enabled},
      dex_enabled = ${dexEnabled},
      vip_results_enabled = ${vipResultsEnabled},
      min_vip_result_multiple = ${minVipResultMultiple},
      updated_at = NOW()
    WHERE id = 1
  `;

  return {
    configured: freeChannelConfigured(),
    enabled,
    dexEnabled,
    vipResultsEnabled,
    minVipResultMultiple,
  };
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

// MEMESCOPE DEX BOOST V3
async function fetchBoostCandidates(): Promise<SourceResult> {
  try {
    const body = await fetchJson(`${DEX_API}/token-boosts/latest/v1`);

    const rows = solanaRows(body)
      .map((row) => {
        const tokenAddress = stringOrNull(row.tokenAddress);
        if (!tokenAddress) return null;

        const amount = numOrNull(row.amount) ?? 0;
        const totalAmount = numOrNull(row.totalAmount) ?? amount;

        return {
          tokenAddress,
          amount,
          totalAmount,
          dexUrl: stringOrNull(row.url),
        };
      })
      .filter(
        (
          item,
        ): item is {
          tokenAddress: string;
          amount: number;
          totalAmount: number;
          dexUrl: string | null;
        } => item !== null,
      );

    const sql = sqlClient();

    const stateRows = await sql`
      SELECT
        token_address,
        last_total_amount,
        last_amount,
        last_seen_at
      FROM memescope_free_boost_state
    `;

    const state = new Map<
      string,
      {
        totalAmount: number;
        amount: number;
        lastSeenAt: number | null;
      }
    >();

    for (const raw of stateRows) {
      const row = raw as DbRow;
      const tokenAddress = String(row.token_address ?? "");
      if (!tokenAddress) continue;

      const lastSeen = row.last_seen_at
        ? Date.parse(String(row.last_seen_at))
        : null;

      state.set(tokenAddress, {
        totalAmount: numOrNull(row.last_total_amount) ?? 0,
        amount: numOrNull(row.last_amount) ?? 0,
        lastSeenAt:
          lastSeen !== null && Number.isFinite(lastSeen)
            ? lastSeen
            : null,
      });
    }

    // First V3 cycle: baseline only, no flood.
    if (state.size === 0) {
      for (const row of rows) {
        await sql`
          INSERT INTO memescope_free_boost_state (
            token_address,
            last_total_amount,
            last_amount,
            last_seen_at,
            updated_at
          ) VALUES (
            ${row.tokenAddress},
            ${row.totalAmount},
            ${row.amount},
            NOW(),
            NOW()
          )
          ON CONFLICT (token_address)
          DO UPDATE SET
            last_total_amount = EXCLUDED.last_total_amount,
            last_amount = EXCLUDED.last_amount,
            last_seen_at = NOW(),
            updated_at = NOW()
        `;
      }

      return { ok: true, candidates: [] };
    }

    const now = Date.now();
    const returnGapMs =
      Math.max(
        2,
        Number(
          process.env.MEMESCOPE_FREE_BOOST_RETURN_MINUTES ?? 3,
        ) || 3,
      ) * 60_000;

    const candidates: PaidCandidate[] = [];

    for (const row of rows) {
      const previous = state.get(row.tokenAddress);
      let candidate: PaidCandidate | null = null;

      if (!previous) {
        candidate = {
          eventKey: `boost-v3:new:${row.tokenAddress}:${row.totalAmount}:${row.amount}`,
          tokenAddress: row.tokenAddress,
          sourceKind: "boost",
          sourceLabel: "DEX BOOST NEW",
          sourceAt: now,
          dexUrl: row.dexUrl,
        };
      } else if (row.totalAmount > previous.totalAmount) {
        candidate = {
          eventKey: `boost-v3:increase:${row.tokenAddress}:${row.totalAmount}`,
          tokenAddress: row.tokenAddress,
          sourceKind: "boost",
          sourceLabel: "DEX BOOST INCREASE",
          sourceAt: now,
          dexUrl: row.dexUrl,
        };
      } else if (
        previous.lastSeenAt !== null &&
        now - previous.lastSeenAt >= returnGapMs
      ) {
        candidate = {
          eventKey: `boost-v3:return:${row.tokenAddress}:${Math.floor(now / 60_000)}`,
          tokenAddress: row.tokenAddress,
          sourceKind: "boost",
          sourceLabel: "DEX BOOST RETURN",
          sourceAt: now,
          dexUrl: row.dexUrl,
        };
      }

      if (candidate) candidates.push(candidate);

      await sql`
        INSERT INTO memescope_free_boost_state (
          token_address,
          last_total_amount,
          last_amount,
          last_seen_at,
          updated_at
        ) VALUES (
          ${row.tokenAddress},
          ${row.totalAmount},
          ${row.amount},
          NOW(),
          NOW()
        )
        ON CONFLICT (token_address)
        DO UPDATE SET
          last_total_amount = EXCLUDED.last_total_amount,
          last_amount = EXCLUDED.last_amount,
          last_seen_at = NOW(),
          updated_at = NOW()
      `;
    }

    return { ok: true, candidates };
  } catch (error) {
    console.error("MemeScope FREE boost V3 source failed:", error);
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
  const status = order.status.toLowerCase();

  return (
    order.paymentTimestamp !== null &&
    (status === "approved" ||
      status === "processing" ||
      status === "on-hold")
  );
}

// MEMESCOPE DEX PAID V2.1
function paidOrderSource(
  type: string,
): Pick<PaidCandidate, "sourceKind" | "sourceLabel"> | null {
  const normalized = type
    .replace(/[_\s-]+/g, "")
    .toLowerCase();

  if (normalized === "tokenprofile") {
    return {
      sourceKind: "profile",
      sourceLabel: "TOKEN PROFILE",
    };
  }

  if (normalized === "communitytakeover") {
    return {
      sourceKind: "community_takeover",
      sourceLabel: "COMMUNITY TAKEOVER",
    };
  }

  if (normalized === "trendingbarad") {
    return {
      sourceKind: "ad",
      sourceLabel: "TRENDING BAR AD",
    };
  }

  if (normalized === "tokenad") {
    return {
      sourceKind: "ad",
      sourceLabel: "DEX AD",
    };
  }

  return null;
}

async function fetchTokenPaidOrderCandidates(
  tokenAddress: string,
  dexUrl: string | null,
): Promise<PaidCandidate[]> {
  try {
    const body = await fetchJson(
      `${DEX_API}/orders/v1/solana/${encodeURIComponent(tokenAddress)}`,
    );

    const newestByType = new Map<string, PaidOrder>();

    for (const order of paidOrders(body)) {
      if (!validPaidOrder(order) || order.paymentTimestamp === null) continue;

      const source = paidOrderSource(order.type);
      if (!source) continue;

      const key = order.type
        .replace(/[_\s-]+/g, "")
        .toLowerCase();

      const previous = newestByType.get(key);

      if (
        !previous ||
        (order.paymentTimestamp ?? 0) >
          (previous.paymentTimestamp ?? 0)
      ) {
        newestByType.set(key, order);
      }
    }

    return Array.from(newestByType.values())
      .map((order): PaidCandidate | null => {
        if (order.paymentTimestamp === null) return null;

        const source = paidOrderSource(order.type);
        if (!source) return null;

        return {
          eventKey:
            `order:${tokenAddress}:${order.type}:${order.paymentTimestamp}`,
          tokenAddress,
          sourceKind: source.sourceKind,
          sourceLabel: source.sourceLabel,
          sourceAt: order.paymentTimestamp,
          dexUrl,
        };
      })
      .filter((item): item is PaidCandidate => item !== null);
  } catch (error) {
    console.error(
      `MemeScope FREE paid-order check failed for ${tokenAddress}:`,
      error,
    );
    return [];
  }
}

async function fetchProfileCandidates(): Promise<SourceResult> {
  try {
    const body = await fetchJson(
      `${DEX_API}/token-profiles/latest/v1`,
    );

    const candidates = solanaRows(body)
      .map((row): PaidCandidate | null => {
        const tokenAddress =
          stringOrNull(row.tokenAddress);

        if (!tokenAddress) return null;

        return {
          eventKey:
            `profile-feed:${tokenAddress}`,
          tokenAddress,
          sourceKind: "profile",
          sourceLabel: "TOKEN PROFILE",
          sourceAt: null,
          dexUrl: stringOrNull(row.url),
        };
      })
      .filter(
        (item): item is PaidCandidate =>
          item !== null,
      );

    return {
      ok: true,
      candidates,
    };
  } catch (error) {
    console.error(
      "MemeScope FREE profile source failed:",
      error,
    );

    return {
      ok: false,
      candidates: [],
    };
  }
}

async function fetchPaidOrderCandidates(
  seeds: PaidCandidate[],
): Promise<SourceResult> {
  try {
    const dexUrlByToken =
      new Map<string, string | null>();

    for (const seed of seeds) {
      if (
        !dexUrlByToken.has(seed.tokenAddress) ||
        seed.dexUrl
      ) {
        dexUrlByToken.set(
          seed.tokenAddress,
          seed.dexUrl,
        );
      }
    }

    // 30 order lookups + the discovery feeds keeps the
    // one-minute cycle comfortably below the 60 rpm family.
    const tokens =
      Array.from(dexUrlByToken.keys())
        .slice(0, 30);

    const candidates: PaidCandidate[] = [];

    for (
      let index = 0;
      index < tokens.length;
      index += 5
    ) {
      const batch =
        tokens.slice(index, index + 5);

      const results =
        await Promise.all(
          batch.map((tokenAddress) =>
            fetchTokenPaidOrderCandidates(
              tokenAddress,
              dexUrlByToken.get(tokenAddress) ??
                null,
            ),
          ),
        );

      for (const rows of results) {
        candidates.push(...rows);
      }
    }

    return {
      ok: true,
      candidates,
    };
  } catch (error) {
    console.error(
      "MemeScope FREE paid-order discovery failed:",
      error,
    );

    return {
      ok: false,
      candidates: [],
    };
  }
}

async function discoverPaidCandidates() {
  const feedResults = await Promise.all([
    fetchBoostCandidates(),
    fetchAdCandidates(),
    fetchCommunityTakeoverCandidates(),
    fetchProfileCandidates(),
  ]);

  const feedCandidates =
    feedResults.flatMap(
      (result) => result.candidates,
    );

  const orderResult =
    await fetchPaidOrderCandidates(
      feedCandidates,
    );

  const results = [
    ...feedResults,
    orderResult,
  ];

  const map =
    new Map<string, PaidCandidate>();

  for (const result of results) {
    for (const candidate of result.candidates) {
      map.set(
        candidate.eventKey,
        candidate,
      );
    }
  }

  return {
    successfulSources:
      results.filter(
        (result) => result.ok,
      ).length,
    candidates:
      Array.from(map.values()),
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
        const info = objectValue(pair.info);
        const liquidityUsd = numOrNull(liquidity?.usd);
        const previousLiquidity = liquidityByAddress.get(address) ?? -1;
        const rankingLiquidity = liquidityUsd ?? 0;

        if (rankingLiquidity < previousLiquidity) continue;

        const marketCapUsd =
          numOrNull(pair.marketCap) ?? numOrNull(pair.fdv);
        const bannerUrl =
          stringOrNull(info?.header) ??
          stringOrNull(info?.headerUrl) ??
          stringOrNull(pair.header) ??
          stringOrNull(pair.headerUrl);
        const imageUrl =
          stringOrNull(info?.imageUrl) ??
          stringOrNull(info?.image) ??
          stringOrNull(pair.imageUrl) ??
          stringOrNull(pair.image);

        result.set(address, {
          tokenAddress: address,
          symbol: stringOrNull(baseToken?.symbol) ?? "TOKEN",
          name: stringOrNull(baseToken?.name) ?? "Unknown Token",
          marketCapUsd,
          liquidityUsd,
          volume24hUsd: numOrNull(volume?.h24),
          dexUrl:
            stringOrNull(pair.url) ??
            "https://dexscreener.com/solana/" + encodeURIComponent(address),
          imageUrl,
          bannerUrl,
        });

        liquidityByAddress.set(address, rankingLiquidity);
      }
    } catch (error) {
      console.error("MemeScope FREE market enrichment failed:", error);
    }
  }

  return result;
}

type FreeTokenMedia = {
  bannerUrl: string | null;
  imageUrl: string | null;
};

let freeProfileMediaCache:
  | {
      loadedAt: number;
      byToken: Map<
        string,
        FreeTokenMedia
      >;
    }
  | null = null;

async function getFreeProfileMediaMap() {
  const now =
    Date.now();

  if (
    freeProfileMediaCache &&
    now -
      freeProfileMediaCache.loadedAt <
      30_000
  ) {
    return freeProfileMediaCache.byToken;
  }

  const byToken =
    new Map<
      string,
      FreeTokenMedia
    >();

  try {
    const body =
      await fetchJson(
        `${DEX_API}/token-profiles/latest/v1`,
      );

    for (const row of objectArray(
      body,
    )) {
      if (
        stringOrNull(
          row.chainId,
        ) !== "solana"
      ) {
        continue;
      }

      const tokenAddress =
        stringOrNull(
          row.tokenAddress,
        );

      if (!tokenAddress) {
        continue;
      }

      byToken.set(
        tokenAddress,
        {
          bannerUrl:
            stringOrNull(
              row.header,
            ) ??
            stringOrNull(
              row.openGraph,
            ),
          imageUrl:
            stringOrNull(
              row.icon,
            ),
        },
      );
    }
  } catch (error) {
    console.error(
      "MemeScope FREE profile media lookup failed:",
      error,
    );
  }

  freeProfileMediaCache = {
    loadedAt: now,
    byToken,
  };

  return byToken;
}

async function resolveFreeTokenMedia(
  tokenAddress: string,
  market:
    | MarketSnapshot
    | null
    | undefined,
) {
  const profiles =
    await getFreeProfileMediaMap();
  const profile =
    profiles.get(tokenAddress);

  return (
    profile?.bannerUrl ??
    market?.bannerUrl ??
    profile?.imageUrl ??
    market?.imageUrl ??
    null
  );
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
  _candidates: PaidCandidate[],
) {
  return [
    "\u{1F4E2} <b>DEX PAID ALERT</b>",
    "",
    `${escapeTelegramHtml(
      market.name,
    )} | <b>$${escapeTelegramHtml(
      market.symbol,
    )}</b>`,
    "",
    `\u251C \u{1F4B0} MC <b>${compactUsd(
      market.marketCapUsd,
    )}</b>`,
    `\u251C \u{1F4CA} Vol 24h <b>${compactUsd(
      market.volume24hUsd,
    )}</b>`,
    `\u2514 \u{1F4A7} Liq <b>${compactUsd(
      market.liquidityUsd,
    )}</b>`,
    "",
    `CA: <code>${escapeTelegramHtml(
      market.tokenAddress,
    )}</code>`,
    "",
    "\u26A0\uFE0F <i>Paid DexScreener activity detected \u2014 not a VIP signal.</i>",
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
  const gain =
    Math.max(
      0,
      (call.peakMultiple - 1) *
        100,
    );

  return [
    `<b>\u{1F680} $${escapeTelegramHtml(
      call.symbol,
    )} \u{1F4B0} +${gain.toFixed(
      gain >= 100 ? 0 : 1,
    )}% AFTER VIP CALL</b>`,
    "",
    `\u{1F4CA} Call MC: <b>${compactUsd(
      call.callMarketCapUsd,
    )}</b> \u2192 Peak MC: <b>${compactUsd(
      call.peakMarketCapUsd,
    )}</b>`,
    `\u{1F4C8} Peak: <b>${multipleText(
      call.peakMultiple,
    )}</b>`,
    "",
    `CA: <code>${escapeTelegramHtml(
      call.tokenAddress,
    )}</code>`,
    "",
    "<i>Selected tracked result. VIP receives MemeScope calls first.</i>",
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

    // MEMESCOPE FREE ADMIN V2
    await sql`
      ALTER TABLE memescope_free_channel_state
      ADD COLUMN IF NOT EXISTS enabled BOOLEAN NOT NULL DEFAULT TRUE
    `;

    await sql`
      ALTER TABLE memescope_free_channel_state
      ADD COLUMN IF NOT EXISTS dex_enabled BOOLEAN NOT NULL DEFAULT TRUE
    `;

    await sql`
      ALTER TABLE memescope_free_channel_state
      ADD COLUMN IF NOT EXISTS vip_results_enabled BOOLEAN NOT NULL DEFAULT TRUE
    `;

    await sql`
      ALTER TABLE memescope_free_channel_state
      ADD COLUMN IF NOT EXISTS min_vip_result_multiple INTEGER NOT NULL DEFAULT 3
    `;

    await sql`
      ALTER TABLE memescope_free_channel_state
      ADD COLUMN IF NOT EXISTS dex_paid_v2_initialized_at TIMESTAMPTZ
    `;

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_free_boost_state (
        token_address TEXT PRIMARY KEY,
        last_total_amount DOUBLE PRECISION NOT NULL DEFAULT 0,
        last_amount DOUBLE PRECISION NOT NULL DEFAULT 0,
        last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      CREATE INDEX IF NOT EXISTS memescope_free_boost_seen_idx
      ON memescope_free_boost_state (last_seen_at DESC)
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

async function baselineDexPaidV2Events() {
  const sql = sqlClient();

  const stateRows = await sql`
    SELECT dex_paid_v2_initialized_at
    FROM memescope_free_channel_state
    WHERE id = 1
    LIMIT 1
  `;

  if (
    (stateRows[0] as DbRow | undefined)
      ?.dex_paid_v2_initialized_at
  ) {
    return {
      initialized: false,
      baselineCount: 0,
    };
  }

  const discovered =
    await discoverPaidCandidates();

  if (discovered.successfulSources === 0) {
    return {
      initialized: false,
      baselineCount: 0,
    };
  }

  let baselineCount = 0;

  for (const candidate of discovered.candidates) {
    const inserted = await sql`
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
        ${
          candidate.sourceAt === null
            ? null
            : new Date(
                candidate.sourceAt,
              ).toISOString()
        },
        TRUE
      )
      ON CONFLICT (event_key) DO NOTHING
      RETURNING event_key
    `;

    if (inserted[0]) {
      baselineCount += 1;
    }
  }

  await sql`
    UPDATE memescope_free_channel_state
    SET
      dex_paid_v2_initialized_at = NOW(),
      updated_at = NOW()
    WHERE id = 1
  `;

  return {
    initialized: true,
    baselineCount,
  };
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
      c.called_at,
      c.call_market_cap_usd,
      c.peak_market_cap_usd,
      c.peak_multiple
    FROM memescope_call_story c
    INNER JOIN memescope_telegram_posts p
      ON p.signal_record_id = c.signal_record_id
    WHERE p.baseline = FALSE
      AND p.first_sent_at IS NOT NULL
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
        calledAt: Date.parse(String(row.called_at)),
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

  const allGroups =
    Array.from(grouped.entries())
      .sort((a, b) => {
        const aAt = Math.max(
          ...a[1].map(
            (item) => item.sourceAt ?? 0,
          ),
        );
        const bAt = Math.max(
          ...b[1].map(
            (item) => item.sourceAt ?? 0,
          ),
        );

        return bAt - aAt;
      });

  if (allGroups.length === 0) {
    return {
      sent: 0,
      discovered:
        discovered.candidates.length,
    };
  }

  // Resolve markets before limiting the queue.
  // Unindexed tokens can no longer block valid alerts behind them.
  const markets =
    await fetchMarketSnapshots(
      allGroups.map(
        ([address]) => address,
      ),
    );

  const groups =
    allGroups
      .filter(
        ([address]) =>
          markets.has(address),
      )
      .slice(
        0,
        Math.max(
          1,
          Math.min(
            10,
            Number(
              process.env
                .MEMESCOPE_FREE_DEX_MAX_PER_CYCLE ??
                6,
            ) || 6,
          ),
        ),
      );

  if (groups.length === 0) {
    return {
      sent: 0,
      discovered:
        discovered.candidates.length,
    };
  }

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
      const mediaUrl =
        await resolveFreeTokenMedia(
          tokenAddress,
          market,
        );
      const text =
        paidAlertText(
          market,
          candidates,
        );

      const message =
        mediaUrl
          ? await freeChannelSendPhotoMessage(
              config.freeChannelId,
              mediaUrl,
              text,
              {
                replyMarkup:
                  freeButtons(
                    dexUrl,
                  ),
              },
            )
          : await freeChannelSendMessage(
              config.freeChannelId,
              text,
              {
                replyMarkup:
                  freeButtons(
                    dexUrl,
                  ),
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

async function publishVipResults(minMultiple: 3 | 5 | 10 = 3) {
  const sql = sqlClient();
  const config = freeChannelConfig();
  const calls = await currentVipResults();
  const markets =
    await fetchMarketSnapshots(
      calls.map(
        (call) => call.tokenAddress,
      ),
    );
  let sent = 0;

  for (const call of calls) {
    const milestone = highestFreeResultMilestone(call.peakMultiple);
    if (milestone === 0 || milestone < minMultiple) continue;

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
      const text =
        vipResultText(call);
      const replyMarkup =
        freeButtons(null);

      let message;

      try {
        const card =
          await renderSignalResultCard(
            {
              symbol:
                call.symbol,
              callMarketCapUsd:
                call.callMarketCapUsd,
              peakMarketCapUsd:
                call.peakMarketCapUsd,
              peakMultiple:
                call.peakMultiple,
              calledAt:
                Number.isFinite(
                  call.calledAt,
                )
                  ? call.calledAt
                  : Date.now(),
              tokenAddress:
                call.tokenAddress,
              publicId:
                call.publicId,
            },
          );

        message =
          await freeChannelSendResultCardMessage(
            config.freeChannelId,
            card,
            text,
            {
              replyMarkup,
            },
          );
      } catch (cardError) {
        console.error(
          "MemeScope FREE result card failed; using token-media fallback:",
          cardError,
        );

        const mediaUrl =
          await resolveFreeTokenMedia(
            call.tokenAddress,
            markets.get(
              call.tokenAddress,
            ),
          );

        message =
          mediaUrl
            ? await freeChannelSendPhotoMessage(
                config.freeChannelId,
                mediaUrl,
                text,
                {
                  replyMarkup,
                },
              )
            : await freeChannelSendMessage(
                config.freeChannelId,
                text,
                {
                  replyMarkup,
                },
              );
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

      console.error("MemeScope FREE VIP result publish failed:", error);
    }
  }

  return { sent };
}

export async function runFreeChannelCycle() {
  if (!freeChannelConfigured()) {
    return {
      configured: false,
      enabled: false,
      initialized: false,
      dexPaidSent: 0,
      vipResultsSent: 0,
    };
  }

  await ensureFreeChannelSchema();
  const settings = await getFreeChannelAdminSettings();

  if (!settings.enabled) {
    return {
      configured: true,
      enabled: false,
      initialized: false,
      dexPaidSent: 0,
      vipResultsSent: 0,
    };
  }

  const dexBaseline = settings.dexEnabled
    ? await baselineDexPaidEvents()
    : { initialized: false, baselineCount: 0 };

  const dexV2Baseline = settings.dexEnabled
    ? await baselineDexPaidV2Events()
    : { initialized: false, baselineCount: 0 };

  const vipBaseline = settings.vipResultsEnabled
    ? await baselineVipResults()
    : { initialized: false, baselineCount: 0 };

  const dex = !settings.dexEnabled
    ? { sent: 0, discovered: 0 }
    : dexBaseline.initialized ||
        dexV2Baseline.initialized
      ? {
          sent: 0,
          discovered:
            dexBaseline.baselineCount +
            dexV2Baseline.baselineCount,
        }
      : await publishDexPaidAlerts();

  const vip = !settings.vipResultsEnabled
    ? { sent: 0 }
    : vipBaseline.initialized
      ? { sent: 0 }
      : await publishVipResults(settings.minVipResultMultiple);

  return {
    configured: true,
    enabled: true,
    dexDetectorVersion: "v3",
    dexEnabled: settings.dexEnabled,
    vipResultsEnabled: settings.vipResultsEnabled,
    minVipResultMultiple: settings.minVipResultMultiple,
    initialized:
      dexBaseline.initialized ||
      dexV2Baseline.initialized ||
      vipBaseline.initialized,
    dexBaselineCount:
      dexBaseline.baselineCount,
    dexV2BaselineCount:
      dexV2Baseline.baselineCount,
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
      calledAt: Date.now() - 2 * 60 * 60 * 1000,
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
    imageUrl: null,
    bannerUrl: null,
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

