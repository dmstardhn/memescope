import {
  NextRequest,
  NextResponse,
} from "next/server";

import type {
  TokenTerminalCandle,
  TokenTerminalMeta,
  TokenTerminalPool,
  TokenTerminalResponse,
  TokenTerminalTimeframe,
  TokenTerminalTrade,
} from "@/lib/token-terminal-types";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const GT =
  "https://api.geckoterminal.com/api/v2";

const GT_HEADERS = {
  Accept:
    "application/json;version=20230203",
};

type JsonRecord = Record<
  string,
  unknown
>;

type GtResource = {
  id?: string;
  type?: string;
  attributes?: JsonRecord;
  relationships?: JsonRecord;
};


type DexPair = {
  chainId?: string;
  dexId?: string;
  pairAddress?: string;

  baseToken?: {
    address?: string;
    name?: string;
    symbol?: string;
  };

  quoteToken?: {
    address?: string;
    name?: string;
    symbol?: string;
  };

  priceUsd?: string | null;

  txns?: Record<
    string,
    {
      buys?: number;
      sells?: number;
    }
  >;

  volume?: Record<
    string,
    number
  >;

  priceChange?: Record<
    string,
    number
  > | null;

  liquidity?: {
    usd?: number;
  } | null;

  fdv?: number | null;
  marketCap?: number | null;
  pairCreatedAt?: number | null;

  info?: {
    imageUrl?: string | null;
    websites?: Array<{
      url?: string;
    }> | null;
    socials?: Array<{
      platform?: string;
      handle?: string;
    }> | null;
  };
};

type DexFallbackResult = {
  pools: TokenTerminalPool[];
  token: TokenTerminalMeta | null;
};

type CacheItem = {
  expiresAt: number;
  payload: TokenTerminalResponse;
};

const cache = new Map<
  string,
  CacheItem
>();

function isSolanaAddress(
  value: string,
) {
  return /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(
    value,
  );
}

function numberValue(
  value: unknown,
  fallback = 0,
) {
  const parsed = Number(value);
  return Number.isFinite(parsed)
    ? parsed
    : fallback;
}

function nullableNumber(
  value: unknown,
) {
  const parsed = Number(value);

  return Number.isFinite(parsed)
    ? parsed
    : null;
}

function stringValue(
  value: unknown,
) {
  return typeof value === "string"
    ? value
    : "";
}

function objectValue(
  value: unknown,
): JsonRecord {
  return value &&
    typeof value === "object" &&
    !Array.isArray(value)
    ? (value as JsonRecord)
    : {};
}

function arrayValue(
  value: unknown,
) {
  return Array.isArray(value)
    ? value
    : [];
}

function relationId(
  relationships: JsonRecord,
  key: string,
) {
  const relation = objectValue(
    relationships[key],
  );

  const data = objectValue(
    relation.data,
  );

  return stringValue(data.id);
}

function parseTimeframe(
  value: string | null,
): TokenTerminalTimeframe {
  if (
    value === "1m" ||
    value === "5m" ||
    value === "15m" ||
    value === "1h" ||
    value === "4h" ||
    value === "1d"
  ) {
    return value;
  }

  return "5m";
}

function timeframeParams(
  timeframe: TokenTerminalTimeframe,
) {
  if (timeframe === "1m") {
    return {
      path: "minute",
      aggregate: "1",
    };
  }

  if (timeframe === "5m") {
    return {
      path: "minute",
      aggregate: "5",
    };
  }

  if (timeframe === "15m") {
    return {
      path: "minute",
      aggregate: "15",
    };
  }

  if (timeframe === "1h") {
    return {
      path: "hour",
      aggregate: "1",
    };
  }

  if (timeframe === "4h") {
    return {
      path: "hour",
      aggregate: "4",
    };
  }

  return {
    path: "day",
    aggregate: "1",
  };
}

async function gtFetch(
  path: string,
  warnings: string[],
) {
  try {
    const response = await fetch(
      `${GT}${path}`,
      {
        headers: GT_HEADERS,
        cache: "no-store",
      },
    );

    if (!response.ok) {
      warnings.push(
        `GeckoTerminal ${response.status}: ${path}`,
      );

      return null;
    }

    return (await response.json()) as JsonRecord;
  } catch (error) {
    warnings.push(
      error instanceof Error
        ? error.message
        : `Failed: ${path}`,
    );

    return null;
  }
}


async function searchGtPools(
  tokenAddress: string,
  warnings: string[],
) {
  const json = await gtFetch(
    `/search/pools?query=${encodeURIComponent(
      tokenAddress,
    )}&network=solana&include=base_token,quote_token,dex&page=1`,
    warnings,
  );

  return arrayValue(json?.data)
    .map((item) =>
      parsePool(
        item as GtResource,
        tokenAddress,
      ),
    )
    .filter(
      (
        item,
      ): item is TokenTerminalPool =>
        item !== null,
    )
    .sort(
      (a, b) =>
        b.liquidityUsd -
        a.liquidityUsd,
    );
}

async function dexFallbackPools(
  tokenAddress: string,
  warnings: string[],
): Promise<DexFallbackResult> {
  try {
    const response = await fetch(
      `https://api.dexscreener.com/token-pairs/v1/solana/${tokenAddress}`,
      {
        headers: {
          Accept: "application/json",
        },
        cache: "no-store",
      },
    );

    if (!response.ok) {
      warnings.push(
        `DexScreener fallback ${response.status}.`,
      );

      return {
        pools: [],
        token: null,
      };
    }

    const raw =
      (await response.json()) as unknown;

    if (!Array.isArray(raw)) {
      return {
        pools: [],
        token: null,
      };
    }

    const rows = (
      raw as DexPair[]
    )
      .filter(
        (pair) =>
          pair.chainId === "solana" &&
          Boolean(pair.pairAddress) &&
          (
            pair.baseToken?.address ===
              tokenAddress ||
            pair.quoteToken?.address ===
              tokenAddress
          ),
      )
      .sort(
        (a, b) =>
          numberValue(
            b.liquidity?.usd,
          ) -
          numberValue(
            a.liquidity?.usd,
          ),
      );

    const pools =
      rows.map((pair) => {
        const isBase =
          pair.baseToken?.address ===
          tokenAddress;

        const tokenSide:
          | "base"
          | "quote" =
          isBase
            ? "base"
            : "quote";

        const tx = (
          key: string,
        ) => ({
          buys: numberValue(
            pair.txns?.[key]?.buys,
          ),
          sells: numberValue(
            pair.txns?.[key]?.sells,
          ),
        });

        return {
          address:
            pair.pairAddress ?? "",

          name:
            `${pair.baseToken?.symbol ?? "?"} / ${pair.quoteToken?.symbol ?? "?"}`,

          dexName:
            pair.dexId ??
            "unknown",

          tokenSide,

          priceUsd:
            isBase
              ? nullableNumber(
                  pair.priceUsd,
                )
              : null,

          liquidityUsd:
            numberValue(
              pair.liquidity?.usd,
            ),

          marketCapUsd:
            isBase
              ? nullableNumber(
                  pair.marketCap,
                )
              : null,

          fdvUsd:
            isBase
              ? nullableNumber(
                  pair.fdv,
                )
              : null,

          createdAt:
            nullableNumber(
              pair.pairCreatedAt,
            ),

          priceChange: {
            m5: nullableNumber(
              pair.priceChange?.m5,
            ),
            h1: nullableNumber(
              pair.priceChange?.h1,
            ),
            h6: nullableNumber(
              pair.priceChange?.h6,
            ),
            h24: nullableNumber(
              pair.priceChange?.h24,
            ),
          },

          volume: {
            m5: numberValue(
              pair.volume?.m5,
            ),
            h1: numberValue(
              pair.volume?.h1,
            ),
            h6: numberValue(
              pair.volume?.h6,
            ),
            h24: numberValue(
              pair.volume?.h24,
            ),
          },

          txns: {
            m5: tx("m5"),
            h1: tx("h1"),
            h24: tx("h24"),
          },
        } satisfies TokenTerminalPool;
      });

    const first =
      rows[0];

    if (!first) {
      return {
        pools,
        token: null,
      };
    }

    const tokenRow =
      first.baseToken?.address ===
      tokenAddress
        ? first.baseToken
        : first.quoteToken;

    const socials =
      first.info?.socials ?? [];

    const token: TokenTerminalMeta =
      {
        address: tokenAddress,

        name:
          tokenRow?.name ??
          "Unknown token",

        symbol:
          tokenRow?.symbol ??
          "UNKNOWN",

        imageUrl:
          first.info?.imageUrl ??
          null,

        description: null,

        websites:
          (
            first.info?.websites ??
            []
          )
            .map(
              (item) =>
                item.url ?? "",
            )
            .filter(Boolean),

        twitter:
          socials.find(
            (item) =>
              item.platform ===
                "twitter" ||
              item.platform === "x",
          )?.handle ?? null,

        telegram:
          socials.find(
            (item) =>
              item.platform ===
              "telegram",
          )?.handle ?? null,

        discord:
          socials.find(
            (item) =>
              item.platform ===
              "discord",
          )?.handle ?? null,
      };

    return {
      pools,
      token,
    };
  } catch (error) {
    warnings.push(
      error instanceof Error
        ? `DexScreener fallback: ${error.message}`
        : "DexScreener fallback failed.",
    );

    return {
      pools: [],
      token: null,
    };
  }
}

async function hydrateGtPoolFromAddress(
  poolAddress: string,
  tokenAddress: string,
  warnings: string[],
) {
  const json = await gtFetch(
    `/networks/solana/pools/${poolAddress}?include=base_token,quote_token,dex`,
    warnings,
  );

  const resource =
    objectValue(json?.data) as GtResource;

  return parsePool(
    resource,
    tokenAddress,
  );
}

function parsePool(
  resource: GtResource,
  tokenAddress: string,
): TokenTerminalPool | null {
  const attributes = objectValue(
    resource.attributes,
  );

  const relationships = objectValue(
    resource.relationships,
  );

  const address = stringValue(
    attributes.address,
  );

  if (!address) {
    return null;
  }

  const baseId = relationId(
    relationships,
    "base_token",
  );

  const quoteId = relationId(
    relationships,
    "quote_token",
  );

  const tokenSide:
    | "base"
    | "quote" =
    quoteId.toLowerCase().endsWith(
      tokenAddress.toLowerCase(),
    )
      ? "quote"
      : "base";

  const priceUsd =
    tokenSide === "base"
      ? nullableNumber(
          attributes.base_token_price_usd,
        )
      : nullableNumber(
          attributes.quote_token_price_usd,
        );

  const priceChanges =
    objectValue(
      attributes.price_change_percentage,
    );

  const volume =
    objectValue(
      attributes.volume_usd,
    );

  const transactions =
    objectValue(
      attributes.transactions,
    );

  function tx(
    key: string,
  ) {
    const item = objectValue(
      transactions[key],
    );

    return {
      buys: numberValue(item.buys),
      sells: numberValue(item.sells),
    };
  }

  const createdAtRaw =
    stringValue(
      attributes.pool_created_at,
    );

  const createdAt =
    createdAtRaw &&
    Number.isFinite(
      Date.parse(createdAtRaw),
    )
      ? Date.parse(createdAtRaw)
      : null;

  const dexRelation =
    objectValue(
      relationships.dex,
    );

  const dexData =
    objectValue(dexRelation.data);

  const dexId =
    stringValue(dexData.id);

  return {
    address,
    name:
      stringValue(
        attributes.name,
      ) || "Unknown pool",

    dexName:
      dexId
        .replace(/^solana_/, "")
        .replace(/_/g, " ") ||
      "unknown",

    tokenSide,
    priceUsd,
    liquidityUsd: numberValue(
      attributes.reserve_in_usd,
    ),

    marketCapUsd:
      nullableNumber(
        attributes.market_cap_usd,
      ),

    fdvUsd:
      nullableNumber(
        attributes.fdv_usd,
      ),

    createdAt,

    priceChange: {
      m5: nullableNumber(
        priceChanges.m5,
      ),
      h1: nullableNumber(
        priceChanges.h1,
      ),
      h6: nullableNumber(
        priceChanges.h6,
      ),
      h24: nullableNumber(
        priceChanges.h24,
      ),
    },

    volume: {
      m5: numberValue(volume.m5),
      h1: numberValue(volume.h1),
      h6: numberValue(volume.h6),
      h24: numberValue(volume.h24),
    },

    txns: {
      m5: tx("m5"),
      h1: tx("h1"),
      h24: tx("h24"),
    },
  };
}

function parseInfo(
  json: JsonRecord | null,
  address: string,
): TokenTerminalMeta {
  const data = objectValue(
    json?.data,
  );

  const attributes =
    objectValue(data.attributes);

  const websites = arrayValue(
    attributes.websites,
  )
    .map((item) => {
      if (typeof item === "string") {
        return item;
      }

      const row = objectValue(item);
      return stringValue(row.url);
    })
    .filter(Boolean);

  return {
    address,

    name:
      stringValue(attributes.name) ||
      "Unknown token",

    symbol:
      stringValue(attributes.symbol) ||
      "UNKNOWN",

    imageUrl:
      stringValue(
        attributes.image_url,
      ) || null,

    description:
      stringValue(
        attributes.description,
      ) || null,

    websites,

    twitter:
      stringValue(
        attributes.twitter_handle,
      ) || null,

    telegram:
      stringValue(
        attributes.telegram_handle,
      ) || null,

    discord:
      stringValue(
        attributes.discord_url,
      ) || null,
  };
}

function parseCandles(
  json: JsonRecord | null,
): TokenTerminalCandle[] {
  const data = objectValue(
    json?.data,
  );

  const attributes =
    objectValue(data.attributes);

  const rows = arrayValue(
    attributes.ohlcv_list,
  );

  const candles: TokenTerminalCandle[] =
    [];

  for (const row of rows) {
    if (!Array.isArray(row)) {
      continue;
    }

    const [
      timestamp,
      open,
      high,
      low,
      close,
      volume,
    ] = row;

    const candle = {
      time: numberValue(timestamp),
      open: numberValue(open),
      high: numberValue(high),
      low: numberValue(low),
      close: numberValue(close),
      volume: numberValue(volume),
    };

    if (
      candle.time > 0 &&
      candle.open > 0 &&
      candle.high > 0 &&
      candle.low > 0 &&
      candle.close > 0
    ) {
      candles.push(candle);
    }
  }

  return candles.sort(
    (a, b) => a.time - b.time,
  );
}

function parseTrades(
  json: JsonRecord | null,
  tokenAddress: string,
): TokenTerminalTrade[] {
  const data = arrayValue(
    json?.data,
  );

  const trades: TokenTerminalTrade[] =
    [];

  for (const raw of data) {
    const resource =
      objectValue(raw);

    const attributes =
      objectValue(
        resource.attributes,
      );

    const kindRaw =
      stringValue(
        attributes.kind,
      ).toLowerCase();

    const kind:
      | "buy"
      | "sell"
      | "unknown" =
      kindRaw === "buy"
        ? "buy"
        : kindRaw === "sell"
          ? "sell"
          : "unknown";

    const timestampRaw =
      stringValue(
        attributes.block_timestamp,
      );

    const timestamp =
      timestampRaw &&
      Number.isFinite(
        Date.parse(timestampRaw),
      )
        ? Date.parse(timestampRaw)
        : Date.now();

    const fromAddress =
      stringValue(
        attributes.from_token_address,
      );

    const toAddress =
      stringValue(
        attributes.to_token_address,
      );

    let priceUsd: number | null =
      null;

    if (
      fromAddress ===
      tokenAddress
    ) {
      priceUsd =
        nullableNumber(
          attributes.price_from_in_usd,
        );
    } else if (
      toAddress === tokenAddress
    ) {
      priceUsd =
        nullableNumber(
          attributes.price_to_in_usd,
        );
    } else {
      priceUsd =
        nullableNumber(
          attributes.price_to_in_usd,
        ) ??
        nullableNumber(
          attributes.price_from_in_usd,
        );
    }

    trades.push({
      txHash:
        stringValue(
          attributes.tx_hash,
        ),

      timestamp,

      kind,

      volumeUsd:
        numberValue(
          attributes.volume_in_usd,
        ),

      priceUsd,

      fromAmount:
        nullableNumber(
          attributes.from_token_amount,
        ),

      toAmount:
        nullableNumber(
          attributes.to_token_amount,
        ),

      maker:
        stringValue(
          attributes.tx_from_address,
        ) || null,
    });
  }

  return trades
    .sort(
      (a, b) =>
        b.timestamp -
        a.timestamp,
    )
    .slice(0, 100);
}

async function getOhlcv(
  poolAddress: string,
  tokenAddress: string,
  timeframe: TokenTerminalTimeframe,
  warnings: string[],
) {
  const mapped =
    timeframeParams(timeframe);

  const query =
    `?aggregate=${mapped.aggregate}` +
    `&limit=240` +
    `&currency=usd` +
    `&token=${encodeURIComponent(
      tokenAddress,
    )}`;

  const primary = await gtFetch(
    `/networks/solana/pools/${poolAddress}/ohlcv/${mapped.path}${query}`,
    warnings,
  );

  const primaryCandles =
    parseCandles(primary);

  if (primaryCandles.length > 0) {
    return primaryCandles;
  }

  const fallback = await gtFetch(
    `/networks/solana/pools/${poolAddress}/ohlcv/${mapped.path}?aggregate=${mapped.aggregate}&limit=240&currency=usd`,
    warnings,
  );

  return parseCandles(
    fallback,
  );
}


const WSOL_MINT =
  "So11111111111111111111111111111111111111112";

const USD_STABLE_MINTS = new Set([
  "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
  "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB",
  "2b1kV6DkPAnxd5ixfnxCpjxmKwqjjaYmCZfHsFu24GXo",
  "2u1tszSeqZ3qBWF3uNGPFc8TzMk2tdiwknnRMWGWjGWH",
]);

type HeliusPriceObservation = {
  timestamp: number;
  signature: string;
  kind: "buy" | "sell";
  targetAmount: number;
  quoteAmount: number;
  quoteKind: "usd" | "sol";
  ratio: number;
};

function getHeliusApiKey() {
  if (process.env.HELIUS_API_KEY) {
    return process.env.HELIUS_API_KEY;
  }

  for (const value of [
    process.env.SOLANA_RPC_URL,
    process.env.SOLANA_WSS_URL,
  ]) {
    if (!value) {
      continue;
    }

    try {
      const url = new URL(value);
      const key =
        url.searchParams.get("api-key");

      if (key) {
        return key;
      }
    } catch {
      // Ignore malformed optional URL.
    }
  }

  return null;
}

function tokenChangeAmount(
  item: unknown,
) {
  const row = objectValue(item);
  const raw =
    objectValue(
      row.rawTokenAmount,
    );

  const amount = Math.abs(
    numberValue(
      raw.tokenAmount,
    ),
  );

  const decimals =
    numberValue(
      raw.decimals,
    );

  const divisor =
    10 ** decimals;

  if (
    amount <= 0 ||
    !Number.isFinite(divisor) ||
    divisor <= 0
  ) {
    return 0;
  }

  return amount / divisor;
}

function tokenAmountForMint(
  items: unknown[],
  mint: string,
) {
  let total = 0;

  for (const item of items) {
    const row =
      objectValue(item);

    if (
      stringValue(row.mint) !==
      mint
    ) {
      continue;
    }

    total +=
      tokenChangeAmount(row);
  }

  return total;
}

function stableAmount(
  items: unknown[],
) {
  for (const item of items) {
    const row =
      objectValue(item);

    const mint =
      stringValue(row.mint);

    if (
      !USD_STABLE_MINTS.has(
        mint,
      )
    ) {
      continue;
    }

    const amount =
      tokenChangeAmount(row);

    if (amount > 0) {
      return amount;
    }
  }

  return 0;
}

function wsolAmount(
  items: unknown[],
) {
  return tokenAmountForMint(
    items,
    WSOL_MINT,
  );
}

function nativeSolAmount(
  item: unknown,
) {
  const row =
    objectValue(item);

  return (
    Math.abs(
      numberValue(row.amount),
    ) / 1_000_000_000
  );
}

function parseHeliusObservation(
  raw: unknown,
  tokenAddress: string,
): HeliusPriceObservation | null {
  const tx =
    objectValue(raw);

  if (
    stringValue(tx.type)
      .toUpperCase() !== "SWAP"
  ) {
    return null;
  }

  const events =
    objectValue(tx.events);

  const swap =
    objectValue(events.swap);

  if (
    Object.keys(swap).length === 0
  ) {
    return null;
  }

  const tokenInputs =
    arrayValue(
      swap.tokenInputs,
    );

  const tokenOutputs =
    arrayValue(
      swap.tokenOutputs,
    );

  const targetIn =
    tokenAmountForMint(
      tokenInputs,
      tokenAddress,
    );

  const targetOut =
    tokenAmountForMint(
      tokenOutputs,
      tokenAddress,
    );

  let kind:
    | "buy"
    | "sell";

  let targetAmount = 0;
  let oppositeTokens:
    unknown[] = [];
  let oppositeNative:
    unknown = null;

  if (
    targetOut > 0 &&
    targetOut >= targetIn
  ) {
    kind = "buy";
    targetAmount = targetOut;
    oppositeTokens =
      tokenInputs;
    oppositeNative =
      swap.nativeInput;
  } else if (targetIn > 0) {
    kind = "sell";
    targetAmount = targetIn;
    oppositeTokens =
      tokenOutputs;
    oppositeNative =
      swap.nativeOutput;
  } else {
    return null;
  }

  const usd =
    stableAmount(
      oppositeTokens,
    );

  if (usd > 0) {
    return {
      timestamp:
        numberValue(
          tx.timestamp,
        ),
      signature:
        stringValue(
          tx.signature,
        ),
      kind,
      targetAmount,
      quoteAmount: usd,
      quoteKind: "usd",
      ratio:
        usd / targetAmount,
    };
  }

  const wrappedSol =
    wsolAmount(
      oppositeTokens,
    );

  const nativeSol =
    nativeSolAmount(
      oppositeNative,
    );

  const sol =
    wrappedSol > 0
      ? wrappedSol
      : nativeSol;

  if (sol <= 0) {
    return null;
  }

  return {
    timestamp:
      numberValue(
        tx.timestamp,
      ),
    signature:
      stringValue(
        tx.signature,
      ),
    kind,
    targetAmount,
    quoteAmount: sol,
    quoteKind: "sol",
    ratio:
      sol / targetAmount,
  };
}

async function heliusSwapHistory(
  poolAddress: string,
  tokenAddress: string,
  warnings: string[],
) {
  const key =
    getHeliusApiKey();

  if (!key) {
    warnings.push(
      "Helius candle fallback skipped: no Helius API key is configured.",
    );

    return [];
  }

  const bases = [
    "https://api-mainnet.helius-rpc.com",
    "https://api.helius.xyz",
  ];

  for (const base of bases) {
    try {
      const url =
        `${base}/v0/addresses/${poolAddress}/transactions` +
        `?api-key=${encodeURIComponent(key)}` +
        `&limit=100` +
        `&type=SWAP` +
        `&sort-order=desc`;

      const response =
        await fetch(url, {
          headers: {
            Accept:
              "application/json",
          },
          cache: "no-store",
        });

      if (!response.ok) {
        warnings.push(
          `Helius swap history ${response.status} from ${base}.`,
        );

        continue;
      }

      const json =
        (await response.json()) as unknown;

      if (!Array.isArray(json)) {
        continue;
      }

      const observations =
        json
          .map((item) =>
            parseHeliusObservation(
              item,
              tokenAddress,
            ),
          )
          .filter(
            (
              item,
            ): item is HeliusPriceObservation =>
              item !== null &&
              item.timestamp > 0 &&
              item.ratio > 0,
          );

      if (
        observations.length > 0
      ) {
        return observations;
      }
    } catch (error) {
      warnings.push(
        error instanceof Error
          ? `Helius candle fallback: ${error.message}`
          : "Helius candle fallback failed.",
      );
    }
  }

  return [];
}

function timeframeSeconds(
  timeframe: TokenTerminalTimeframe,
) {
  if (timeframe === "1m") {
    return 60;
  }

  if (timeframe === "5m") {
    return 300;
  }

  if (timeframe === "15m") {
    return 900;
  }

  if (timeframe === "1h") {
    return 3_600;
  }

  if (timeframe === "4h") {
    return 14_400;
  }

  return 86_400;
}

function buildFallbackCandles(
  observations: HeliusPriceObservation[],
  currentPriceUsd: number | null,
  timeframe: TokenTerminalTimeframe,
) {
  const usdObservations =
    observations.filter(
      (item) =>
        item.quoteKind === "usd",
    );

  const solObservations =
    observations.filter(
      (item) =>
        item.quoteKind === "sol",
    );

  const selected =
    usdObservations.length > 0
      ? usdObservations
      : solObservations;

  if (selected.length === 0) {
    return {
      candles:
        [] as TokenTerminalCandle[],
      trades:
        [] as TokenTerminalTrade[],
      mode:
        "none" as const,
    };
  }

  let multiplier = 1;

  if (
    selected[0].quoteKind ===
    "sol"
  ) {
    if (
      !currentPriceUsd ||
      currentPriceUsd <= 0
    ) {
      return {
        candles:
          [] as TokenTerminalCandle[],
        trades:
          [] as TokenTerminalTrade[],
        mode:
          "none" as const,
      };
    }

    const latest =
      selected
        .slice()
        .sort(
          (a, b) =>
            b.timestamp -
            a.timestamp,
        )[0];

    if (
      !latest ||
      latest.ratio <= 0
    ) {
      return {
        candles:
          [] as TokenTerminalCandle[],
        trades:
          [] as TokenTerminalTrade[],
        mode:
          "none" as const,
      };
    }

    multiplier =
      currentPriceUsd /
      latest.ratio;
  }

  const normalized =
    selected
      .map((item) => ({
        ...item,
        priceUsd:
          item.ratio *
          multiplier,
        volumeUsd:
          item.quoteAmount *
          multiplier,
      }))
      .filter(
        (item) =>
          Number.isFinite(
            item.priceUsd,
          ) &&
          item.priceUsd > 0,
      )
      .sort(
        (a, b) =>
          a.timestamp -
          b.timestamp,
      );

  const bucketSize =
    timeframeSeconds(
      timeframe,
    );

  const buckets =
    new Map<
      number,
      TokenTerminalCandle
    >();

  for (const item of normalized) {
    const time =
      Math.floor(
        item.timestamp /
          bucketSize,
      ) * bucketSize;

    const existing =
      buckets.get(time);

    if (!existing) {
      buckets.set(time, {
        time,
        open: item.priceUsd,
        high: item.priceUsd,
        low: item.priceUsd,
        close: item.priceUsd,
        volume:
          item.volumeUsd,
      });

      continue;
    }

    existing.high =
      Math.max(
        existing.high,
        item.priceUsd,
      );

    existing.low =
      Math.min(
        existing.low,
        item.priceUsd,
      );

    existing.close =
      item.priceUsd;

    existing.volume +=
      item.volumeUsd;
  }

  const candles =
    Array.from(
      buckets.values(),
    ).sort(
      (a, b) =>
        a.time - b.time,
    );

  const trades: TokenTerminalTrade[] =
    normalized
      .slice()
      .sort(
        (a, b) =>
          b.timestamp -
          a.timestamp,
      )
      .slice(0, 100)
      .map((item) => ({
        txHash:
          item.signature,
        timestamp:
          item.timestamp *
          1000,
        kind: item.kind,
        volumeUsd:
          item.volumeUsd,
        priceUsd:
          item.priceUsd,
        fromAmount: null,
        toAmount: null,
        maker: null,
      }));

  return {
    candles,
    trades,
    mode:
      selected[0].quoteKind ===
      "usd"
        ? ("stable" as const)
        : ("sol-anchored" as const),
  };
}

async function heliusCandleFallback(
  poolAddress: string,
  tokenAddress: string,
  currentPriceUsd: number | null,
  timeframe: TokenTerminalTimeframe,
  warnings: string[],
) {
  const observations =
    await heliusSwapHistory(
      poolAddress,
      tokenAddress,
      warnings,
    );

  const result =
    buildFallbackCandles(
      observations,
      currentPriceUsd,
      timeframe,
    );

  if (
    result.mode ===
    "stable"
  ) {
    warnings.push(
      "Chart fallback: candles reconstructed from recent on-chain Helius swaps against USD stablecoins.",
    );
  }

  if (
    result.mode ===
    "sol-anchored"
  ) {
    warnings.push(
      "Chart fallback: token/SOL swap ratios were reconstructed from Helius and anchored to the current USD token price. Historical USD values are estimates.",
    );
  }

  return result;
}

export async function GET(
  request: NextRequest,
  context: {
    params: Promise<{
      address: string;
    }>;
  },
) {
  const { address } =
    await context.params;

  if (!isSolanaAddress(address)) {
    return NextResponse.json(
      {
        error:
          "Invalid Solana token address.",
      },
      {
        status: 400,
      },
    );
  }

  const timeframe =
    parseTimeframe(
      request.nextUrl.searchParams.get(
        "tf",
      ),
    );

  const requestedPool =
    request.nextUrl.searchParams.get(
      "pool",
    );

  const cacheKey =
    `${address}:${requestedPool ?? "top"}:${timeframe}`;

  const cached =
    cache.get(cacheKey);

  if (
    cached &&
    cached.expiresAt > Date.now()
  ) {
    return NextResponse.json(
      cached.payload,
    );
  }

  const warnings: string[] = [];

  const [poolJson, infoJson] =
    await Promise.all([
      gtFetch(
        `/networks/solana/tokens/${address}/pools?include=base_token,quote_token,dex&include_inactive_source=true&page=1`,
        warnings,
      ),

      gtFetch(
        `/networks/solana/tokens/${address}/info`,
        warnings,
      ),
    ]);

  const poolData =
    arrayValue(poolJson?.data);

  let pools =
    poolData
      .map((item) =>
        parsePool(
          item as GtResource,
          address,
        ),
      )
      .filter(
        (
          item,
        ): item is TokenTerminalPool =>
          item !== null,
      )
      .sort(
        (a, b) =>
          b.liquidityUsd -
          a.liquidityUsd,
      );

  let usedDexFallback = false;
  let dexToken:
    | TokenTerminalMeta
    | null = null;

  if (pools.length === 0) {
    const searched =
      await searchGtPools(
        address,
        warnings,
      );

    if (searched.length > 0) {
      pools = searched;
    }
  }

  if (pools.length === 0) {
    const fallback =
      await dexFallbackPools(
        address,
        warnings,
      );

    dexToken = fallback.token;

    if (fallback.pools.length > 0) {
      usedDexFallback = true;

      const topFallback =
        fallback.pools[0];

      const geckoPool =
        await hydrateGtPoolFromAddress(
          topFallback.address,
          address,
          warnings,
        );

      if (geckoPool) {
        pools = [
          geckoPool,
          ...fallback.pools.filter(
            (item) =>
              item.address !==
              geckoPool.address,
          ),
        ];
      } else {
        pools =
          fallback.pools;
      }
    }
  }

  if (pools.length === 0) {
    return NextResponse.json(
      {
        error:
          "No market pool found for this token across GeckoTerminal or the DexScreener fallback.",
        warnings,
      },
      {
        status: 404,
      },
    );
  }

  const selectedPool =
    pools.find(
      (pool) =>
        pool.address ===
        requestedPool,
    ) ?? pools[0];

  const [geckoCandles, tradesJson] =
    await Promise.all([
      getOhlcv(
        selectedPool.address,
        address,
        timeframe,
        warnings,
      ),

      gtFetch(
        `/networks/solana/pools/${selectedPool.address}/trades`,
        warnings,
      ),
    ]);

  let candles =
    geckoCandles;

  let trades =
    parseTrades(
      tradesJson,
      address,
    );

  let chartSource:
    | "GeckoTerminal OHLCV"
    | "Helius reconstructed"
    | "Unavailable" =
    candles.length > 0
      ? "GeckoTerminal OHLCV"
      : "Unavailable";

  if (candles.length === 0) {
    const fallback =
      await heliusCandleFallback(
        selectedPool.address,
        address,
        selectedPool.priceUsd,
        timeframe,
        warnings,
      );

    if (
      fallback.candles.length > 0
    ) {
      candles =
        fallback.candles;

      chartSource =
        "Helius reconstructed";

      if (
        trades.length === 0 &&
        fallback.trades.length > 0
      ) {
        trades =
          fallback.trades;
      }
    }
  }

  const token =
    parseInfo(
      infoJson,
      address,
    );

  if (
    dexToken &&
    token.symbol === "UNKNOWN"
  ) {
    token.symbol =
      dexToken.symbol;
    token.name =
      dexToken.name;
    token.imageUrl =
      dexToken.imageUrl;
    token.websites =
      dexToken.websites;
    token.twitter =
      dexToken.twitter;
    token.telegram =
      dexToken.telegram;
    token.discord =
      dexToken.discord;
  }

  const poolNameParts =
    selectedPool.name.split(
      " / ",
    );

  if (
    token.symbol === "UNKNOWN" &&
    poolNameParts[0]
  ) {
    token.symbol =
      poolNameParts[0];
  }

  if (
    token.name === "Unknown token"
  ) {
    token.name =
      token.symbol;
  }

  const payload: TokenTerminalResponse =
    {
      generatedAt: Date.now(),
      network: "solana",
      timeframe,
      token,
      selectedPool,
      pools: pools.slice(0, 12),
      candles,
      trades,
      source: {
        market: usedDexFallback
          ? "DexScreener fallback"
          : "GeckoTerminal",
        onchain:
          "MemeScope/Helius",
        chart: chartSource,
      },
      warnings,
    };

  cache.set(cacheKey, {
    expiresAt:
      Date.now() + 45_000,
    payload,
  });

  return NextResponse.json(
    payload,
  );
}
