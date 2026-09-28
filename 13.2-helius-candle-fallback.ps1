$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " MemeScope Stage 13.2 - Helius Candle Fallback" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

$root = (Get-Location).Path
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )

    $full = Join-Path $root $Path
    $dir = Split-Path -Parent $full

    if ($dir -and !(Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    [System.IO.File]::WriteAllText($full, $Content, $utf8NoBom)
    Write-Host "Updated: $Path" -ForegroundColor Green
}

if (!(Test-Path -LiteralPath (Join-Path $root "package.json"))) {
    throw "package.json not found. Run this script from the memecoin-analyst project root."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $root ".backup-stage13-2-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

foreach ($file in @(
    "src/app/api/token-terminal/solana/[address]/route.ts",
    "src/lib/token-terminal-types.ts",
    "src/app/token/[address]/page.tsx"
)) {
    $full = Join-Path $root $file

    if (Test-Path -LiteralPath $full) {
        $safe = ($file -replace '[\\/]', '__') + ".bak"
        Copy-Item -LiteralPath $full -Destination (Join-Path $backupDir $safe) -Force
    }
}

Write-Host "Backup: $backupDir" -ForegroundColor DarkGray

$route = @'
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

'@

$types = @'
export type TokenTerminalTimeframe =
  | "1m"
  | "5m"
  | "15m"
  | "1h"
  | "4h"
  | "1d";

export type TokenTerminalCandle = {
  time: number;
  open: number;
  high: number;
  low: number;
  close: number;
  volume: number;
};

export type TokenTerminalPool = {
  address: string;
  name: string;
  dexName: string;
  tokenSide: "base" | "quote";
  priceUsd: number | null;
  liquidityUsd: number;
  marketCapUsd: number | null;
  fdvUsd: number | null;
  createdAt: number | null;

  priceChange: {
    m5: number | null;
    h1: number | null;
    h6: number | null;
    h24: number | null;
  };

  volume: {
    m5: number;
    h1: number;
    h6: number;
    h24: number;
  };

  txns: {
    m5: {
      buys: number;
      sells: number;
    };
    h1: {
      buys: number;
      sells: number;
    };
    h24: {
      buys: number;
      sells: number;
    };
  };
};

export type TokenTerminalTrade = {
  txHash: string;
  timestamp: number;
  kind: "buy" | "sell" | "unknown";
  volumeUsd: number;
  priceUsd: number | null;
  fromAmount: number | null;
  toAmount: number | null;
  maker: string | null;
};

export type TokenTerminalMeta = {
  address: string;
  name: string;
  symbol: string;
  imageUrl: string | null;
  description: string | null;
  websites: string[];
  twitter: string | null;
  telegram: string | null;
  discord: string | null;
};

export type TokenTerminalResponse = {
  generatedAt: number;
  network: "solana";
  timeframe: TokenTerminalTimeframe;
  token: TokenTerminalMeta;
  selectedPool: TokenTerminalPool;
  pools: TokenTerminalPool[];
  candles: TokenTerminalCandle[];
  trades: TokenTerminalTrade[];
  source: {
    market: "GeckoTerminal" | "DexScreener fallback";
    onchain: "MemeScope/Helius";
    chart:
      | "GeckoTerminal OHLCV"
      | "Helius reconstructed"
      | "Unavailable";
  };
  warnings: string[];
};

'@

$page = @'
"use client";

import {
  Activity,
  Bookmark,
  BookmarkCheck,
  Bot,
  Copy,
  ExternalLink,
  Globe2,
  RefreshCw,
  ShieldCheck,
  Users,
} from "lucide-react";
import {
  use,
  useEffect,
  useMemo,
  useState,
} from "react";

import {
  TokenCandles,
} from "@/components/token-candles";

import type {
  SolanaRiskReport,
} from "@/lib/risk-types";

import type {
  TokenTerminalPool,
  TokenTerminalResponse,
  TokenTerminalTimeframe,
} from "@/lib/token-terminal-types";

const WATCHLIST_KEY =
  "memescope-token-watchlist";

const TIMEFRAMES: TokenTerminalTimeframe[] =
  [
    "1m",
    "5m",
    "15m",
    "1h",
    "4h",
    "1d",
  ];

function money(
  value: number | null | undefined,
) {
  if (
    value === null ||
    value === undefined ||
    !Number.isFinite(value)
  ) {
    return "N/A";
  }

  if (Math.abs(value) >= 1_000_000_000) {
    return `$${(
      value / 1_000_000_000
    ).toFixed(2)}B`;
  }

  if (Math.abs(value) >= 1_000_000) {
    return `$${(
      value / 1_000_000
    ).toFixed(2)}M`;
  }

  if (Math.abs(value) >= 1_000) {
    return `$${(
      value / 1_000
    ).toFixed(1)}K`;
  }

  if (Math.abs(value) >= 1) {
    return `$${value.toFixed(4)}`;
  }

  return `$${value.toPrecision(5)}`;
}

function percent(
  value: number | null,
) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return "N/A";
  }

  return `${value > 0 ? "+" : ""}${value.toFixed(
    2,
  )}%`;
}

function short(
  value: string,
) {
  if (value.length <= 14) {
    return value;
  }

  return `${value.slice(
    0,
    6,
  )}...${value.slice(-5)}`;
}

function ageFromTimestamp(
  timestamp: number | null,
) {
  if (!timestamp) {
    return "N/A";
  }

  const minutes = Math.max(
    0,
    Math.floor(
      (Date.now() - timestamp) /
        60_000,
    ),
  );

  if (minutes < 60) {
    return `${minutes}m`;
  }

  if (minutes < 1_440) {
    return `${Math.floor(
      minutes / 60,
    )}h`;
  }

  return `${Math.floor(
    minutes / 1_440,
  )}d`;
}

function timeAgo(
  timestamp: number,
) {
  const seconds = Math.max(
    0,
    Math.floor(
      (Date.now() - timestamp) /
        1000,
    ),
  );

  if (seconds < 60) {
    return `${seconds}s ago`;
  }

  if (seconds < 3_600) {
    return `${Math.floor(
      seconds / 60,
    )}m ago`;
  }

  return `${Math.floor(
    seconds / 3_600,
  )}h ago`;
}

function PoolRow({
  pool,
  active,
  onSelect,
}: {
  pool: TokenTerminalPool;
  active: boolean;
  onSelect: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onSelect}
      className={`grid w-full grid-cols-[1fr_auto_auto] items-center gap-4 border-b border-white/5 px-4 py-3 text-left transition ${
        active
          ? "bg-emerald-400/[0.05]"
          : "hover:bg-white/[0.025]"
      }`}
    >
      <div className="min-w-0">
        <div className="truncate text-xs font-medium text-zinc-200">
          {pool.name}
        </div>

        <div className="mt-1 text-[10px] text-zinc-700">
          {pool.dexName}
          {" | "}
          {short(pool.address)}
        </div>
      </div>

      <div className="text-right">
        <div className="text-[10px] text-zinc-700">
          Liquidity
        </div>

        <div className="mt-1 text-xs text-zinc-300">
          {money(
            pool.liquidityUsd,
          )}
        </div>
      </div>

      <div className="text-right">
        <div className="text-[10px] text-zinc-700">
          24h volume
        </div>

        <div className="mt-1 text-xs text-zinc-300">
          {money(pool.volume.h24)}
        </div>
      </div>
    </button>
  );
}

export default function TokenPage({
  params,
}: {
  params: Promise<{
    address: string;
  }>;
}) {
  const { address } =
    use(params);

  const [data, setData] =
    useState<TokenTerminalResponse | null>(
      null,
    );

  const [risk, setRisk] =
    useState<SolanaRiskReport | null>(
      null,
    );

  const [timeframe, setTimeframe] =
    useState<TokenTerminalTimeframe>(
      "5m",
    );

  const [pool, setPool] =
    useState<string | null>(
      null,
    );

  const [loading, setLoading] =
    useState(true);

  const [chartLoading, setChartLoading] =
    useState(false);

  const [error, setError] =
    useState("");

  const [saved, setSaved] =
    useState(false);

  useEffect(() => {
    try {
      const raw =
        localStorage.getItem(
          WATCHLIST_KEY,
        );

      const values = raw
        ? (JSON.parse(raw) as unknown)
        : [];

      if (Array.isArray(values)) {
        setSaved(
          values.includes(address),
        );
      }
    } catch {
      setSaved(false);
    }
  }, [address]);

  async function loadTerminal(
    options?: {
      silent?: boolean;
      nextTf?: TokenTerminalTimeframe;
      nextPool?: string | null;
    },
  ) {
    const silent =
      options?.silent ?? false;

    const nextTf =
      options?.nextTf ??
      timeframe;

    const nextPool =
      options?.nextPool ??
      pool;

    if (!silent) {
      setChartLoading(true);
    }

    try {
      const query =
        new URLSearchParams({
          tf: nextTf,
        });

      if (nextPool) {
        query.set(
          "pool",
          nextPool,
        );
      }

      const response = await fetch(
        `/api/token-terminal/solana/${address}?${query.toString()}`,
        {
          cache: "no-store",
        },
      );

      const result =
        (await response.json()) as
          | TokenTerminalResponse
          | {
              error?: string;
            };

      if (!response.ok) {
        throw new Error(
          "error" in result
            ? result.error
            : "Token terminal failed.",
        );
      }

      const terminal =
        result as TokenTerminalResponse;

      setData(terminal);
      setPool(
        terminal.selectedPool.address,
      );
      setError("");
    } catch (loadError) {
      setError(
        loadError instanceof Error
          ? loadError.message
          : "Token terminal failed.",
      );
    } finally {
      setChartLoading(false);
      setLoading(false);
    }
  }

  async function loadRisk() {
    try {
      const response = await fetch(
        `/api/risk/solana/${address}`,
        {
          cache: "no-store",
        },
      );

      const result =
        (await response.json()) as SolanaRiskReport;

      if (response.ok) {
        setRisk(result);
      }
    } catch {
      // Risk panel is optional.
    }
  }

  useEffect(() => {
    void Promise.all([
      loadTerminal(),
      loadRisk(),
    ]);

    const timer = window.setInterval(
      () => {
        void loadTerminal({
          silent: true,
        });
      },
      45_000,
    );

    return () =>
      window.clearInterval(timer);
  }, [address]);

  const buyShare5m =
    useMemo(() => {
      if (!data) {
        return null;
      }

      const buys =
        data.selectedPool.txns.m5
          .buys;

      const sells =
        data.selectedPool.txns.m5
          .sells;

      const total = buys + sells;

      return total > 0
        ? buys / total
        : null;
    }, [data]);

  function toggleWatchlist() {
    let values: string[] = [];

    try {
      const raw =
        localStorage.getItem(
          WATCHLIST_KEY,
        );

      const parsed = raw
        ? (JSON.parse(raw) as unknown)
        : [];

      if (Array.isArray(parsed)) {
        values = parsed.filter(
          (
            item,
          ): item is string =>
            typeof item ===
            "string",
        );
      }
    } catch {
      values = [];
    }

    const exists =
      values.includes(address);

    const next = exists
      ? values.filter(
          (item) =>
            item !== address,
        )
      : Array.from(
          new Set([
            ...values,
            address,
          ]),
        );

    localStorage.setItem(
      WATCHLIST_KEY,
      JSON.stringify(next),
    );

    setSaved(!exists);
  }

  async function changeTimeframe(
    next: TokenTerminalTimeframe,
  ) {
    setTimeframe(next);

    await loadTerminal({
      nextTf: next,
    });
  }

  async function changePool(
    nextPool: string,
  ) {
    setPool(nextPool);

    await loadTerminal({
      nextPool,
    });
  }

  if (loading && !data) {
    return (
      <main className="flex min-h-[70vh] items-center justify-center">
        <div className="text-center">
          <RefreshCw className="mx-auto h-5 w-5 animate-spin text-emerald-300" />

          <div className="mt-3 text-sm text-zinc-500">
            Loading native token terminal...
          </div>
        </div>
      </main>
    );
  }

  if (!data) {
    return (
      <main className="mx-auto max-w-4xl px-5 py-10">
        <div className="rounded-2xl border border-red-400/20 bg-red-400/[0.05] p-5 text-sm text-red-200">
          {error ||
            "Token market data unavailable."}
        </div>
      </main>
    );
  }

  const selected =
    data.selectedPool;

  return (
    <main className="mx-auto w-full max-w-[1900px] px-3 py-4 lg:px-5">
      <section className="mb-4 flex flex-wrap items-start justify-between gap-4">
        <div className="flex min-w-0 items-center gap-3">
          {data.token.imageUrl ? (
            <img
              src={
                data.token.imageUrl
              }
              alt=""
              className="h-12 w-12 rounded-full border border-white/10 object-cover"
            />
          ) : (
            <div className="flex h-12 w-12 items-center justify-center rounded-full border border-white/10 bg-white/5 text-sm font-bold text-zinc-500">
              {data.token.symbol.slice(
                0,
                2,
              )}
            </div>
          )}

          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <h1 className="text-xl font-semibold text-white">
                {data.token.symbol}
              </h1>

              <span className="text-sm text-zinc-600">
                {data.token.name}
              </span>

              <span className="rounded-md border border-white/10 px-1.5 py-0.5 text-[9px] uppercase text-zinc-600">
                SOL
              </span>
            </div>

            <div className="mt-1 flex flex-wrap items-center gap-2 text-[11px] text-zinc-600">
              <button
                type="button"
                onClick={() =>
                  navigator.clipboard.writeText(
                    address,
                  )
                }
                className="flex items-center gap-1 hover:text-zinc-300"
              >
                {short(address)}
                <Copy className="h-3 w-3" />
              </button>

              <span>|</span>

              <span>
                {selected.dexName}
              </span>

              <span>|</span>

              <span>
                age{" "}
                {ageFromTimestamp(
                  selected.createdAt,
                )}
              </span>
            </div>
          </div>
        </div>

        <div className="flex flex-wrap gap-2">
          <button
            type="button"
            onClick={toggleWatchlist}
            className={`flex items-center gap-2 rounded-xl border px-3 py-2 text-xs ${
              saved
                ? "border-emerald-400/20 bg-emerald-400/10 text-emerald-300"
                : "border-white/10 text-zinc-400 hover:bg-white/5"
            }`}
          >
            {saved ? (
              <BookmarkCheck className="h-3.5 w-3.5" />
            ) : (
              <Bookmark className="h-3.5 w-3.5" />
            )}

            {saved
              ? "Watching"
              : "Watch"}
          </button>

          <a
            href={`/analyst?address=${address}`}
            className="flex items-center gap-2 rounded-xl border border-white/10 px-3 py-2 text-xs text-zinc-400 hover:bg-white/5"
          >
            <Bot className="h-3.5 w-3.5" />
            AI Analyst
          </a>

          <button
            type="button"
            onClick={() => {
              void loadTerminal();
              void loadRisk();
            }}
            className="flex items-center gap-2 rounded-xl border border-white/10 px-3 py-2 text-xs text-zinc-400 hover:bg-white/5"
          >
            <RefreshCw className="h-3.5 w-3.5" />
            Refresh
          </button>
        </div>
      </section>

      <section className="mb-4 grid grid-cols-2 gap-2 md:grid-cols-4 xl:grid-cols-8">
        {[
          [
            "Price",
            money(
              selected.priceUsd,
            ),
          ],
          [
            "5m",
            percent(
              selected.priceChange.m5,
            ),
          ],
          [
            "1h",
            percent(
              selected.priceChange.h1,
            ),
          ],
          [
            "24h",
            percent(
              selected.priceChange.h24,
            ),
          ],
          [
            "Liquidity",
            money(
              selected.liquidityUsd,
            ),
          ],
          [
            "Market Cap",
            money(
              selected.marketCapUsd ??
                selected.fdvUsd,
            ),
          ],
          [
            "Vol 24h",
            money(
              selected.volume.h24,
            ),
          ],
          [
            "Buy share 5m",
            buyShare5m !== null
              ? `${Math.round(
                  buyShare5m * 100,
                )}%`
              : "N/A",
          ],
        ].map(([label, value]) => (
          <div
            key={String(label)}
            className="rounded-xl border border-white/10 bg-white/[0.025] p-3"
          >
            <div className="text-[9px] uppercase tracking-[0.13em] text-zinc-700">
              {label}
            </div>

            <div className="mt-1 text-sm font-semibold text-zinc-100">
              {value}
            </div>
          </div>
        ))}
      </section>

      <div className="grid gap-4 2xl:grid-cols-[minmax(0,1fr)_350px]">
        <div className="min-w-0 space-y-4">
          <section className="overflow-hidden rounded-2xl border border-white/10 bg-[#090b0f]">
            <div className="flex flex-wrap items-center justify-between gap-3 border-b border-white/5 px-4 py-3">
              <div>
                <div className="text-sm font-semibold text-white">
                  Price Chart
                </div>

                <div className="mt-1 flex flex-wrap items-center gap-2 text-[10px] text-zinc-700">
                  <span>
                    Native MemeScope chart
                  </span>

                  <span className={`rounded-md border px-1.5 py-0.5 ${
                    data.source.chart === "Helius reconstructed"
                      ? "border-amber-400/15 bg-amber-400/[0.05] text-amber-300/70"
                      : data.source.chart === "GeckoTerminal OHLCV"
                        ? "border-emerald-400/15 bg-emerald-400/[0.05] text-emerald-300/70"
                        : "border-white/10 text-zinc-600"
                  }`}>
                    {data.source.chart}
                  </span>
                </div>
              </div>

              <div className="flex items-center gap-1">
                {TIMEFRAMES.map(
                  (item) => (
                    <button
                      key={item}
                      type="button"
                      onClick={() =>
                        void changeTimeframe(
                          item,
                        )
                      }
                      className={`rounded-lg px-2.5 py-1.5 text-[11px] ${
                        timeframe === item
                          ? "bg-white text-black"
                          : "text-zinc-500 hover:bg-white/5 hover:text-white"
                      }`}
                    >
                      {item}
                    </button>
                  ),
                )}
              </div>
            </div>

            <div className="relative">
              {chartLoading && (
                <div className="absolute right-4 top-3 z-20 flex items-center gap-2 rounded-lg bg-black/60 px-2 py-1 text-[10px] text-zinc-400">
                  <RefreshCw className="h-3 w-3 animate-spin" />
                  Loading
                </div>
              )}

              <TokenCandles
                candles={
                  data.candles
                }
              />
            </div>
          </section>

          <section className="overflow-hidden rounded-2xl border border-white/10 bg-white/[0.02]">
            <div className="flex items-center justify-between border-b border-white/5 px-4 py-3">
              <div>
                <div className="flex items-center gap-2 text-sm font-semibold text-white">
                  <Activity className="h-4 w-4 text-emerald-300" />
                  Recent Trades
                </div>

                <div className="mt-1 text-[10px] text-zinc-700">
                  Latest trades from the selected liquidity pool
                </div>
              </div>

              <span className="text-[10px] text-zinc-700">
                {data.trades.length} loaded
              </span>
            </div>

            <div className="max-h-[520px] overflow-auto">
              <table className="w-full min-w-[760px] text-left text-xs">
                <thead className="sticky top-0 bg-[#0d1015] text-[9px] uppercase tracking-[0.12em] text-zinc-700">
                  <tr>
                    <th className="px-4 py-3">
                      Time
                    </th>
                    <th className="px-3 py-3">
                      Side
                    </th>
                    <th className="px-3 py-3">
                      USD
                    </th>
                    <th className="px-3 py-3">
                      Price
                    </th>
                    <th className="px-3 py-3">
                      Maker
                    </th>
                    <th className="px-3 py-3">
                      Tx
                    </th>
                  </tr>
                </thead>

                <tbody>
                  {data.trades.map(
                    (trade) => (
                      <tr
                        key={`${trade.txHash}-${trade.timestamp}`}
                        className="border-t border-white/5"
                      >
                        <td className="px-4 py-3 text-zinc-500">
                          {timeAgo(
                            trade.timestamp,
                          )}
                        </td>

                        <td
                          className={`px-3 py-3 font-medium ${
                            trade.kind ===
                            "buy"
                              ? "text-emerald-300"
                              : trade.kind ===
                                  "sell"
                                ? "text-red-300"
                                : "text-zinc-500"
                          }`}
                        >
                          {trade.kind.toUpperCase()}
                        </td>

                        <td className="px-3 py-3 text-zinc-200">
                          {money(
                            trade.volumeUsd,
                          )}
                        </td>

                        <td className="px-3 py-3 font-mono text-zinc-400">
                          {money(
                            trade.priceUsd,
                          )}
                        </td>

                        <td className="px-3 py-3 font-mono text-[10px] text-zinc-600">
                          {trade.maker
                            ? short(
                                trade.maker,
                              )
                            : "N/A"}
                        </td>

                        <td className="px-3 py-3">
                          {trade.txHash ? (
                            <a
                              href={`https://solscan.io/tx/${trade.txHash}`}
                              target="_blank"
                              rel="noreferrer"
                              className="text-zinc-600 hover:text-white"
                            >
                              <ExternalLink className="h-3.5 w-3.5" />
                            </a>
                          ) : (
                            "N/A"
                          )}
                        </td>
                      </tr>
                    ),
                  )}
                </tbody>
              </table>

              {data.trades.length ===
                0 && (
                <div className="p-8 text-center text-sm text-zinc-600">
                  No recent trades returned for this pool.
                </div>
              )}
            </div>
          </section>

          <section className="overflow-hidden rounded-2xl border border-white/10 bg-white/[0.02]">
            <div className="flex items-center gap-2 border-b border-white/5 px-4 py-3 text-sm font-semibold text-white">
              <Globe2 className="h-4 w-4 text-cyan-300" />
              Liquidity Pools
            </div>

            <div>
              {data.pools.map(
                (item) => (
                  <PoolRow
                    key={item.address}
                    pool={item}
                    active={
                      item.address ===
                      selected.address
                    }
                    onSelect={() =>
                      void changePool(
                        item.address,
                      )
                    }
                  />
                ),
              )}
            </div>
          </section>
        </div>

        <aside className="space-y-4">
          <section className="rounded-2xl border border-white/10 bg-white/[0.025] p-5">
            <div className="flex items-center gap-2 text-sm font-semibold text-white">
              <ShieldCheck className="h-4 w-4 text-emerald-300" />
              MemeScope Risk
            </div>

            {risk ? (
              <>
                <div className="mt-5 flex items-end justify-between">
                  <div>
                    <div className="text-[10px] uppercase tracking-[0.15em] text-zinc-700">
                      Risk score
                    </div>

                    <div className="mt-1 text-4xl font-semibold text-white">
                      {risk.riskScore}
                    </div>
                  </div>

                  <div
                    className={`rounded-lg px-2.5 py-1.5 text-xs ${
                      risk.riskLabel ===
                      "Low"
                        ? "bg-emerald-400/10 text-emerald-300"
                        : risk.riskLabel ===
                            "Moderate"
                          ? "bg-amber-400/10 text-amber-300"
                          : "bg-red-400/10 text-red-300"
                    }`}
                  >
                    {risk.riskLabel}
                  </div>
                </div>

                <div className="mt-5 space-y-2">
                  <div className="flex justify-between gap-4 rounded-lg bg-black/20 px-3 py-2 text-xs">
                    <span className="text-zinc-600">
                      Mint authority
                    </span>

                    <span className="text-zinc-300">
                      {risk.mintAuthorityDisabled ===
                      null
                        ? "N/A"
                        : risk.mintAuthorityDisabled
                          ? "Disabled"
                          : "Active"}
                    </span>
                  </div>

                  <div className="flex justify-between gap-4 rounded-lg bg-black/20 px-3 py-2 text-xs">
                    <span className="text-zinc-600">
                      Freeze authority
                    </span>

                    <span className="text-zinc-300">
                      {risk.freezeAuthorityDisabled ===
                      null
                        ? "N/A"
                        : risk.freezeAuthorityDisabled
                          ? "Disabled"
                          : "Active"}
                    </span>
                  </div>

                  <div className="flex justify-between gap-4 rounded-lg bg-black/20 px-3 py-2 text-xs">
                    <span className="text-zinc-600">
                      Top 10 observed
                    </span>

                    <span className="text-zinc-300">
                      {risk.analyzedOwnerCount >
                      0
                        ? `${risk.top10Percentage.toFixed(
                            1,
                          )}%`
                        : "N/A"}
                    </span>
                  </div>
                </div>

                <div className="mt-4 space-y-2">
                  {risk.flags
                    .slice(0, 5)
                    .map((flag) => (
                      <div
                        key={flag.id}
                        className="rounded-lg border border-white/5 px-3 py-2"
                      >
                        <div className="text-xs font-medium text-zinc-300">
                          {flag.title}
                        </div>

                        <div className="mt-1 text-[10px] leading-4 text-zinc-600">
                          {flag.description}
                        </div>
                      </div>
                    ))}
                </div>
              </>
            ) : (
              <div className="py-8 text-center text-xs text-zinc-600">
                Risk data unavailable or still loading.
              </div>
            )}
          </section>

          <section className="rounded-2xl border border-white/10 bg-white/[0.025] p-5">
            <div className="flex items-center gap-2 text-sm font-semibold text-white">
              <Users className="h-4 w-4 text-cyan-300" />
              Pool Activity
            </div>

            <div className="mt-4 grid grid-cols-2 gap-2">
              {[
                [
                  "5m Buys",
                  selected.txns.m5.buys,
                ],
                [
                  "5m Sells",
                  selected.txns.m5.sells,
                ],
                [
                  "1h Buys",
                  selected.txns.h1.buys,
                ],
                [
                  "1h Sells",
                  selected.txns.h1.sells,
                ],
                [
                  "24h Buys",
                  selected.txns.h24.buys,
                ],
                [
                  "24h Sells",
                  selected.txns.h24.sells,
                ],
              ].map(
                ([label, value]) => (
                  <div
                    key={String(label)}
                    className="rounded-lg bg-black/20 p-3"
                  >
                    <div className="text-[9px] text-zinc-700">
                      {label}
                    </div>

                    <div className="mt-1 text-sm font-medium text-zinc-200">
                      {value}
                    </div>
                  </div>
                ),
              )}
            </div>
          </section>

          <section className="rounded-2xl border border-white/10 bg-white/[0.025] p-5">
            <div className="text-sm font-semibold text-white">
              Token Links
            </div>

            <div className="mt-4 space-y-2">
              {data.token.websites
                .slice(0, 2)
                .map((url, index) => (
                  <a
                    key={`${url}-${index}`}
                    href={url}
                    target="_blank"
                    rel="noreferrer"
                    className="flex items-center justify-between rounded-lg border border-white/5 px-3 py-2 text-xs text-zinc-500 hover:text-white"
                  >
                    Website
                    <ExternalLink className="h-3.5 w-3.5" />
                  </a>
                ))}

              {data.token.twitter && (
                <a
                  href={`https://x.com/${data.token.twitter.replace(
                    /^@/,
                    "",
                  )}`}
                  target="_blank"
                  rel="noreferrer"
                  className="flex items-center justify-between rounded-lg border border-white/5 px-3 py-2 text-xs text-zinc-500 hover:text-white"
                >
                  X / Twitter
                  <ExternalLink className="h-3.5 w-3.5" />
                </a>
              )}

              <a
                href={`https://solscan.io/token/${address}`}
                target="_blank"
                rel="noreferrer"
                className="flex items-center justify-between rounded-lg border border-white/5 px-3 py-2 text-xs text-zinc-500 hover:text-white"
              >
                Solscan
                <ExternalLink className="h-3.5 w-3.5" />
              </a>
            </div>
          </section>

          <section className="rounded-xl border border-white/5 bg-black/20 p-4 text-[10px] leading-4 text-zinc-700">
            Market chart, pools and recent trades are rendered directly inside MemeScope. Market data source: {data.source.market}. On-chain risk source: MemeScope using the configured Solana RPC.
          </section>
        </aside>
      </div>

      {error && (
        <div className="mt-4 rounded-xl border border-amber-400/15 bg-amber-400/[0.04] p-3 text-xs text-amber-100/70">
          {error}
        </div>
      )}
    </main>
  );
}

'@

Write-Utf8NoBom "src/app/api/token-terminal/solana/[address]/route.ts" $route
Write-Utf8NoBom "src/lib/token-terminal-types.ts" $types
Write-Utf8NoBom "src/app/token/[address]/page.tsx" $page

Remove-Item -Recurse -Force (Join-Path $root ".next") -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host " Stage 13.2 installed" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Candle resolution order:" -ForegroundColor Cyan
Write-Host " 1. GeckoTerminal OHLCV"
Write-Host " 2. Helius recent on-chain SWAP history for the pool"
Write-Host " 3. Stablecoin swaps become direct USD candles"
Write-Host " 4. SOL swaps are reconstructed and anchored to current USD token price"
Write-Host ""
Write-Host "No API key needs to be pasted." -ForegroundColor Green
Write-Host "The server reuses HELIUS_API_KEY or the api-key already inside SOLANA_RPC_URL."
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "npm run typecheck"
Write-Host "npm run dev"
Write-Host ""
