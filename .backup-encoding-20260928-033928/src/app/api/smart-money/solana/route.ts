import { NextRequest, NextResponse } from "next/server";

import type {
  SmartMoneyEvent,
  SmartMoneyResponse,
  SmartMoneySignal,
} from "@/lib/smart-money-types";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type Json = Record<string, unknown>;

type RpcRequest = {
  id: number;
  method: string;
  params: unknown[];
};

type TokenBalance = {
  mint?: string;
  owner?: string;
  uiTokenAmount?: {
    uiAmount?: number | null;
    uiAmountString?: string;
  };
};

type DexPair = {
  chainId?: string;
  dexId?: string;
  url?: string;
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
  liquidity?: {
    usd?: number | null;
  };
  marketCap?: number | null;
  fdv?: number | null;
  volume?: {
    m5?: number | null;
  };
  txns?: {
    m5?: {
      buys?: number;
      sells?: number;
    };
  };
  priceChange?: {
    m5?: number | null;
  };
  pairCreatedAt?: number | null;
};

const WSOL = "So11111111111111111111111111111111111111112";
const USDC = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";

const IGNORE_MINTS = new Set([WSOL, USDC]);

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isSolanaAddress(value: string) {
  return /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(value);
}

function getRpcUrl() {
  const value = process.env.SOLANA_RPC_URL?.trim();

  if (!value) {
    throw new Error(
      "SOLANA_RPC_URL belum dikonfigurasi. Tambahkan private Solana RPC di .env.local.",
    );
  }

  return value;
}

async function rpc(
  request: RpcRequest,
): Promise<unknown> {
  const rpcUrl = getRpcUrl();

  for (let attempt = 1; attempt <= 4; attempt++) {
    const response = await fetch(rpcUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: request.id,
        method: request.method,
        params: request.params,
      }),
      cache: "no-store",
    });

    if (response.status === 429) {
      if (attempt === 4) {
        throw new Error("Solana RPC rate limit reached.");
      }

      await sleep(500 * 2 ** (attempt - 1));
      continue;
    }

    if (!response.ok) {
      throw new Error(`Solana RPC ${response.status}`);
    }

    const data = (await response.json()) as {
      result?: unknown;
      error?: { message?: string };
    };

    if (data.error) {
      throw new Error(data.error.message || `${request.method} failed`);
    }

    return data.result;
  }

  throw new Error(`${request.method} failed`);
}

async function rpcBatch(
  requests: RpcRequest[],
): Promise<Map<number, unknown>> {
  const rpcUrl = getRpcUrl();

  if (requests.length === 0) {
    return new Map();
  }

  for (let attempt = 1; attempt <= 4; attempt++) {
    const response = await fetch(rpcUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(
        requests.map((request) => ({
          jsonrpc: "2.0",
          id: request.id,
          method: request.method,
          params: request.params,
        })),
      ),
      cache: "no-store",
    });

    if (response.status === 429) {
      if (attempt === 4) {
        throw new Error("Solana RPC batch rate limit reached.");
      }

      await sleep(700 * 2 ** (attempt - 1));
      continue;
    }

    if (!response.ok) {
      throw new Error(`Solana RPC ${response.status}`);
    }

    const payload = (await response.json()) as Array<{
      id?: number;
      result?: unknown;
      error?: { message?: string };
    }>;

    const output = new Map<number, unknown>();

    for (const item of Array.isArray(payload) ? payload : []) {
      if (typeof item.id !== "number") continue;
      if (item.error) continue;
      output.set(item.id, item.result);
    }

    return output;
  }

  return new Map();
}

function tokenAmount(balance: TokenBalance | undefined) {
  if (!balance?.uiTokenAmount) return 0;

  const raw =
    balance.uiTokenAmount.uiAmountString ??
    String(balance.uiTokenAmount.uiAmount ?? "0");

  const value = Number(raw);
  return Number.isFinite(value) ? value : 0;
}

function balancesForWallet(
  balances: unknown,
  wallet: string,
) {
  const map = new Map<string, number>();

  if (!Array.isArray(balances)) return map;

  for (const raw of balances) {
    const balance = raw as TokenBalance;

    if (balance.owner !== wallet || !balance.mint) {
      continue;
    }

    const amount = tokenAmount(balance);
    map.set(
      balance.mint,
      (map.get(balance.mint) ?? 0) + amount,
    );
  }

  return map;
}

function parseInflows(
  transaction: unknown,
  wallet: string,
  signature: string,
  fallbackTimestamp: number,
): SmartMoneyEvent[] {
  if (!transaction || typeof transaction !== "object") return [];

  const tx = transaction as {
    blockTime?: number | null;
    meta?: {
      err?: unknown;
      preTokenBalances?: unknown;
      postTokenBalances?: unknown;
    } | null;
  };

  if (!tx.meta || tx.meta.err) return [];

  const pre = balancesForWallet(
    tx.meta.preTokenBalances,
    wallet,
  );

  const post = balancesForWallet(
    tx.meta.postTokenBalances,
    wallet,
  );

  const mints = new Set([
    ...Array.from(pre.keys()),
    ...Array.from(post.keys()),
  ]);

  const timestamp =
    typeof tx.blockTime === "number"
      ? tx.blockTime * 1000
      : fallbackTimestamp;

  const events: SmartMoneyEvent[] = [];

  for (const mint of mints) {
    if (IGNORE_MINTS.has(mint)) continue;

    const before = pre.get(mint) ?? 0;
    const after = post.get(mint) ?? 0;
    const delta = after - before;

    if (!Number.isFinite(delta) || delta <= 0) continue;

    events.push({
      wallet,
      mint,
      amount: delta,
      timestamp,
      signature,
    });
  }

  return events;
}

async function fetchWalletEvents(
  wallet: string,
  signatureLimit: number,
  windowStart: number,
  idSeed: number,
) {
  const signatures = (await rpc({
    id: idSeed,
    method: "getSignaturesForAddress",
    params: [
      wallet,
      {
        limit: signatureLimit,
        commitment: "confirmed",
      },
    ],
  })) as Array<{
    signature?: string;
    blockTime?: number | null;
    err?: unknown;
  }> | null;

  const usable = (signatures ?? []).filter(
    (item) =>
      item.signature &&
      !item.err &&
      (!item.blockTime ||
        item.blockTime * 1000 >= windowStart),
  );

  const requests: RpcRequest[] = usable.map(
    (item, index) => ({
      id: idSeed + 100 + index,
      method: "getTransaction",
      params: [
        item.signature,
        {
          encoding: "jsonParsed",
          commitment: "confirmed",
          maxSupportedTransactionVersion: 0,
        },
      ],
    }),
  );

  const transactions = await rpcBatch(requests);
  const events: SmartMoneyEvent[] = [];

  usable.forEach((item, index) => {
    const signature = item.signature;
    if (!signature) return;

    const tx = transactions.get(idSeed + 100 + index);

    events.push(
      ...parseInflows(
        tx,
        wallet,
        signature,
        item.blockTime
          ? item.blockTime * 1000
          : Date.now(),
      ),
    );
  });

  return {
    events,
    signatureCount: usable.length,
    transactionCount: transactions.size,
  };
}

function chooseBestPair(
  mint: string,
  pairs: DexPair[],
) {
  const candidates = pairs.filter((pair) => {
    return (
      pair.chainId === "solana" &&
      (pair.baseToken?.address === mint ||
        pair.quoteToken?.address === mint)
    );
  });

  candidates.sort(
    (a, b) =>
      (b.liquidity?.usd ?? 0) -
      (a.liquidity?.usd ?? 0),
  );

  return candidates[0] ?? null;
}

async function fetchDexData(mints: string[]) {
  const output = new Map<string, DexPair>();

  for (let index = 0; index < mints.length; index += 30) {
    const chunk = mints.slice(index, index + 30);

    const response = await fetch(
      `https://api.dexscreener.com/tokens/v1/solana/${chunk.join(",")}`,
      {
        headers: {
          Accept: "application/json",
        },
        cache: "no-store",
      },
    );

    if (!response.ok) continue;

    const pairs = (await response.json()) as DexPair[];

    for (const mint of chunk) {
      const best = chooseBestPair(
        mint,
        Array.isArray(pairs) ? pairs : [],
      );

      if (best) output.set(mint, best);
    }
  }

  return output;
}

function clamp(value: number, min: number, max: number) {
  return Math.max(min, Math.min(max, value));
}

function buildAttentionScore(
  walletCount: number,
  latestTimestamp: number,
  pair: DexPair | null,
) {
  const minutesAgo = Math.max(
    0,
    (Date.now() - latestTimestamp) / 60_000,
  );

  const walletScore = Math.min(
    52,
    walletCount * 18,
  );

  const recencyScore = clamp(
    22 - minutesAgo * 0.7,
    0,
    22,
  );

  const liquidity = pair?.liquidity?.usd ?? 0;

  let liquidityScore = 0;
  if (liquidity >= 250_000) liquidityScore = 12;
  else if (liquidity >= 100_000) liquidityScore = 10;
  else if (liquidity >= 50_000) liquidityScore = 8;
  else if (liquidity >= 20_000) liquidityScore = 5;
  else if (liquidity >= 5_000) liquidityScore = 2;

  const buys = pair?.txns?.m5?.buys ?? 0;
  const sells = pair?.txns?.m5?.sells ?? 0;
  const total = buys + sells;

  const buyShare =
    total > 0 ? buys / total : 0.5;

  const flowScore =
    total >= 10
      ? clamp((buyShare - 0.45) * 40, 0, 10)
      : 0;

  const pairCreatedAt = pair?.pairCreatedAt ?? 0;
  const ageHours =
    pairCreatedAt > 0
      ? (Date.now() - pairCreatedAt) / 3_600_000
      : Number.POSITIVE_INFINITY;

  const earlyScore =
    ageHours <= 6 ? 4 : ageHours <= 24 ? 2 : 0;

  return Math.round(
    clamp(
      walletScore +
        recencyScore +
        liquidityScore +
        flowScore +
        earlyScore,
      0,
      100,
    ),
  );
}

function tokenIdentity(
  mint: string,
  pair: DexPair | null,
) {
  if (!pair) {
    return {
      symbol: `${mint.slice(0, 4)}â€¦${mint.slice(-4)}`,
      name: "Unknown token",
    };
  }

  if (pair.baseToken?.address === mint) {
    return {
      symbol: pair.baseToken.symbol || "UNKNOWN",
      name: pair.baseToken.name || "Unknown token",
    };
  }

  return {
    symbol: pair.quoteToken?.symbol || "UNKNOWN",
    name: pair.quoteToken?.name || "Unknown token",
  };
}

export async function POST(request: NextRequest) {
  try {
    const body = (await request.json()) as {
      wallets?: unknown;
      windowMinutes?: unknown;
      signatureLimit?: unknown;
    };

    const rawWallets = Array.isArray(body.wallets)
      ? body.wallets
      : [];

    const wallets = Array.from(
      new Set(
        rawWallets
          .filter((value): value is string => typeof value === "string")
          .map((value) => value.trim())
          .filter(isSolanaAddress),
      ),
    ).slice(0, 12);

    if (wallets.length === 0) {
      return NextResponse.json(
        {
          error:
            "Tambahkan minimal satu Solana wallet address yang valid.",
        },
        { status: 400 },
      );
    }

    const windowMinutes = clamp(
      Number(body.windowMinutes) || 30,
      5,
      180,
    );

    const signatureLimit = Math.round(
      clamp(
        Number(body.signatureLimit) || 8,
        3,
        15,
      ),
    );

    const windowStart =
      Date.now() - windowMinutes * 60_000;

    const events: SmartMoneyEvent[] = [];
    const warnings: string[] = [];

    let signaturesInspected = 0;
    let transactionsInspected = 0;
    let walletsAnalyzed = 0;

    // Sequential by wallet to stay friendly to lower RPC plans.
    for (let index = 0; index < wallets.length; index++) {
      const wallet = wallets[index];

      try {
        const result = await fetchWalletEvents(
          wallet,
          signatureLimit,
          windowStart,
          1_000 + index * 1_000,
        );

        events.push(...result.events);
        signaturesInspected += result.signatureCount;
        transactionsInspected += result.transactionCount;
        walletsAnalyzed += 1;
      } catch (error) {
        warnings.push(
          `${wallet.slice(0, 5)}â€¦${wallet.slice(-4)}: ${
            error instanceof Error
              ? error.message
              : "wallet scan failed"
          }`,
        );
      }

      if (index < wallets.length - 1) {
        await sleep(110);
      }
    }

    const recentEvents = events
      .filter((event) => event.timestamp >= windowStart)
      .sort((a, b) => b.timestamp - a.timestamp);

    const grouped = new Map<
      string,
      {
        wallets: Set<string>;
        eventCount: number;
        totalTokenInflow: number;
        latestTimestamp: number;
      }
    >();

    for (const event of recentEvents) {
      const current = grouped.get(event.mint) ?? {
        wallets: new Set<string>(),
        eventCount: 0,
        totalTokenInflow: 0,
        latestTimestamp: 0,
      };

      current.wallets.add(event.wallet);
      current.eventCount += 1;
      current.totalTokenInflow += event.amount;
      current.latestTimestamp = Math.max(
        current.latestTimestamp,
        event.timestamp,
      );

      grouped.set(event.mint, current);
    }

    const mints = Array.from(grouped.keys()).slice(0, 60);
    const dexData = await fetchDexData(mints);

    const signals: SmartMoneySignal[] = Array.from(
      grouped.entries(),
    ).map(([mint, aggregate]) => {
      const pair = dexData.get(mint) ?? null;
      const identity = tokenIdentity(mint, pair);

      const walletsForMint = Array.from(
        aggregate.wallets,
      );

      return {
        mint,
        symbol: identity.symbol,
        name: identity.name,
        walletCount: walletsForMint.length,
        wallets: walletsForMint,
        eventCount: aggregate.eventCount,
        totalTokenInflow: aggregate.totalTokenInflow,
        latestTimestamp: aggregate.latestTimestamp,

        priceUsd: pair?.priceUsd
          ? Number(pair.priceUsd)
          : null,

        liquidityUsd:
          typeof pair?.liquidity?.usd === "number"
            ? pair.liquidity.usd
            : null,

        marketCap:
          typeof pair?.marketCap === "number"
            ? pair.marketCap
            : null,

        fdv:
          typeof pair?.fdv === "number"
            ? pair.fdv
            : null,

        volume5m:
          typeof pair?.volume?.m5 === "number"
            ? pair.volume.m5
            : null,

        buys5m:
          typeof pair?.txns?.m5?.buys === "number"
            ? pair.txns.m5.buys
            : null,

        sells5m:
          typeof pair?.txns?.m5?.sells === "number"
            ? pair.txns.m5.sells
            : null,

        priceChange5m:
          typeof pair?.priceChange?.m5 === "number"
            ? pair.priceChange.m5
            : null,

        pairCreatedAt:
          typeof pair?.pairCreatedAt === "number"
            ? pair.pairCreatedAt
            : null,

        dexUrl: pair?.url ?? null,

        attentionScore: buildAttentionScore(
          walletsForMint.length,
          aggregate.latestTimestamp,
          pair,
        ),

        classification:
          walletsForMint.length >= 2
            ? "cluster"
            : "single",
      };
    });

    signals.sort((a, b) => {
      if (b.walletCount !== a.walletCount) {
        return b.walletCount - a.walletCount;
      }

      if (b.attentionScore !== a.attentionScore) {
        return b.attentionScore - a.attentionScore;
      }

      return b.latestTimestamp - a.latestTimestamp;
    });

    const response: SmartMoneyResponse = {
      generatedAt: Date.now(),
      walletsRequested: wallets.length,
      walletsAnalyzed,
      signaturesInspected,
      transactionsInspected,
      windowMinutes,
      signals,
      events: recentEvents.slice(0, 100),
      warnings,
    };

    return NextResponse.json(response);
  } catch (error) {
    console.error("[Smart Money]", error);

    return NextResponse.json(
      {
        error:
          error instanceof Error
            ? error.message
            : "Smart Money analysis failed.",
      },
      { status: 500 },
    );
  }
}