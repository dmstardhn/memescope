import { NextRequest, NextResponse } from "next/server";
import type {
  WalletActivity,
  WalletHolding,
  WalletReport,
} from "@/lib/wallet-types";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const PUBLIC_RPC = "https://api.mainnet.solana.com";
const CACHE_MS = 2_000;
const MAX_HOLDINGS = 12;
const MAX_SIGNATURES = 8;

const cache = new Map<
  string,
  { expiresAt: number; report: WalletReport }
>();

type Json = Record<string, any>;

function n(value: unknown) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function clamp(value: number, min = 0, max = 100) {
  return Math.min(max, Math.max(min, value));
}

async function rpc(
  rpcUrl: string,
  method: string,
  params: unknown[],
  id: number,
) {
  const response = await fetch(rpcUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id,
      method,
      params,
    }),
    cache: "no-store",
  });

  if (!response.ok) {
    throw new Error(`Solana RPC returned ${response.status}`);
  }

  const data = (await response.json()) as Json;

  if (data.error) {
    throw new Error(
      data.error.message || `${method} failed`,
    );
  }

  return data.result;
}

async function rpcBatchTransactions(
  rpcUrl: string,
  signatures: string[],
) {
  if (!signatures.length) return [];

  const body = signatures.map((signature, index) => ({
    jsonrpc: "2.0",
    id: index + 100,
    method: "getTransaction",
    params: [
      signature,
      {
        commitment: "confirmed",
        maxSupportedTransactionVersion: 0,
        encoding: "jsonParsed",
      },
    ],
  }));

  const response = await fetch(rpcUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify(body),
    cache: "no-store",
  });

  if (!response.ok) {
    throw new Error(
      `Solana transaction batch returned ${response.status}`,
    );
  }

  const data = (await response.json()) as Json[];

  if (!Array.isArray(data)) return [];

  return data
    .sort((a, b) => n(a.id) - n(b.id))
    .map((item) => item.result ?? null);
}

async function fetchDexData(mints: string[]) {
  const unique = Array.from(new Set(mints)).slice(0, 30);

  if (!unique.length) {
    return new Map<string, Json>();
  }

  const joined = unique
    .map((mint) => encodeURIComponent(mint))
    .join(",");

  const response = await fetch(
    `https://api.dexscreener.com/tokens/v1/solana/${joined}`,
    {
      headers: {
        Accept: "application/json",
        "User-Agent": "MemeScope/0.5",
      },
      cache: "no-store",
    },
  );

  if (!response.ok) {
    return new Map<string, Json>();
  }

  const data = await response.json();
  const pairs = Array.isArray(data)
    ? data
    : Array.isArray(data?.pairs)
      ? data.pairs
      : [];

  const best = new Map<string, Json>();

  for (const pair of pairs as Json[]) {
    const mint = pair?.baseToken?.address;
    if (!mint) continue;

    const existing = best.get(mint);
    const existingLiq = n(existing?.liquidity?.usd);
    const nextLiq = n(pair?.liquidity?.usd);

    if (!existing || nextLiq > existingLiq) {
      best.set(mint, pair);
    }
  }

  return best;
}

function tokenAmount(balance: Json) {
  return n(
    balance?.uiTokenAmount?.uiAmountString ??
      balance?.uiTokenAmount?.uiAmount,
  );
}

function ownerBalances(
  balances: Json[] | undefined,
  owner: string,
) {
  const map = new Map<string, number>();

  for (const item of balances || []) {
    if (item?.owner !== owner || !item?.mint) continue;

    map.set(
      item.mint,
      (map.get(item.mint) || 0) + tokenAmount(item),
    );
  }

  return map;
}

function buildActivity(
  wallet: string,
  signatures: Json[],
  transactions: Array<Json | null>,
) {
  const activities: WalletActivity[] = [];
  const touched = new Set<string>();

  transactions.forEach((tx, index) => {
    if (!tx) return;

    const sig = signatures[index];
    const pre = ownerBalances(
      tx?.meta?.preTokenBalances,
      wallet,
    );
    const post = ownerBalances(
      tx?.meta?.postTokenBalances,
      wallet,
    );

    const mints = new Set([
      ...pre.keys(),
      ...post.keys(),
    ]);

    let created = 0;

    for (const mint of mints) {
      const delta =
        (post.get(mint) || 0) -
        (pre.get(mint) || 0);

      if (Math.abs(delta) < 1e-12) continue;

      touched.add(mint);

      activities.push({
        signature:
          sig?.signature ||
          tx?.transaction?.signatures?.[0] ||
          "",
        blockTime:
          typeof tx?.blockTime === "number"
            ? tx.blockTime
            : sig?.blockTime ?? null,
        status:
          tx?.meta?.err == null
            ? "success"
            : "failed",
        mint,
        delta,
        direction:
          delta > 0 ? "acquired" : "disposed",
        currentPriceUsd: 0,
        currentDeltaValueUsd: 0,
      });

      created += 1;
      if (created >= 3) break;
    }

    if (created === 0) {
      activities.push({
        signature:
          sig?.signature ||
          tx?.transaction?.signatures?.[0] ||
          "",
        blockTime:
          typeof tx?.blockTime === "number"
            ? tx.blockTime
            : sig?.blockTime ?? null,
        status:
          tx?.meta?.err == null
            ? "success"
            : "failed",
        mint: null,
        delta: 0,
        direction: "other",
        currentPriceUsd: 0,
        currentDeltaValueUsd: 0,
      });
    }
  });

  return {
    activities: activities.slice(0, 18),
    touched,
  };
}

export async function GET(
  request: NextRequest,
  context: { params: Promise<{ address: string }> },
) {
  const { address } = await context.params;

  if (!/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(address)) {
    return NextResponse.json(
      { ok: false, error: "Invalid Solana wallet address." },
      { status: 400 },
    );
  }

  const forceFresh =
    request.nextUrl.searchParams.get("fresh") === "1";

  const cached = cache.get(address);

  if (
    !forceFresh &&
    cached &&
    Date.now() < cached.expiresAt
  ) {
    return NextResponse.json(cached.report, {
      headers: { "Cache-Control": "no-store" },
    });
  }

  const customRpc = process.env.SOLANA_RPC_URL?.trim();
  const rpcUrl = customRpc || PUBLIC_RPC;
  const now = Date.now();

  try {
    const [balanceResult, tokenAccountsResult, signatures] =
      await Promise.all([
        rpc(
          rpcUrl,
          "getBalance",
          [address, { commitment: "confirmed" }],
          1,
        ),
        rpc(
          rpcUrl,
          "getTokenAccountsByOwner",
          [
            address,
            { programId: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA" },
            {
              encoding: "jsonParsed",
              commitment: "confirmed",
            },
          ],
          2,
        ),
        rpc(
          rpcUrl,
          "getSignaturesForAddress",
          [
            address,
            {
              commitment: "confirmed",
              limit: MAX_SIGNATURES,
            },
          ],
          3,
        ),
      ]);

    const rawAccounts = Array.isArray(
      tokenAccountsResult?.value,
    )
      ? tokenAccountsResult.value
      : [];

    const rawHoldings = rawAccounts
      .map((item: Json) => {
        const info =
          item?.account?.data?.parsed?.info;
        const mint = info?.mint;
        const token = info?.tokenAmount;

        return {
          mint,
          amount: n(
            token?.uiAmountString ??
              token?.uiAmount,
          ),
          decimals: n(token?.decimals),
        };
      })
      .filter(
        (item: Json) =>
          item.mint && item.amount > 0,
      )
      .sort(
        (a: Json, b: Json) =>
          b.amount - a.amount,
      )
      .slice(0, MAX_HOLDINGS);

    const signatureList = Array.isArray(signatures)
      ? signatures
      : [];

    let transactions: Array<Json | null> = [];

    try {
      transactions = await rpcBatchTransactions(
        rpcUrl,
        signatureList.map(
          (item: Json) => item.signature,
        ),
      );
    } catch {
      transactions = [];
    }

    const activityData = buildActivity(
      address,
      signatureList,
      transactions,
    );

    const allMints = Array.from(
      new Set([
        ...rawHoldings.map(
          (item: Json) => item.mint,
        ),
        ...Array.from(activityData.touched),
      ]),
    );

    const dex = await fetchDexData(allMints);

    const holdings: WalletHolding[] =
      rawHoldings.map((item: Json) => {
        const pair = dex.get(item.mint);
        const priceUsd = n(pair?.priceUsd);
        const amount = n(item.amount);

        return {
          mint: item.mint,
          amount,
          decimals: n(item.decimals),
          symbol:
            pair?.baseToken?.symbol || null,
          name:
            pair?.baseToken?.name || null,
          priceUsd,
          valueUsd: amount * priceUsd,
          marketCap: n(
            pair?.marketCap ?? pair?.fdv,
          ),
          liquidity: n(
            pair?.liquidity?.usd,
          ),
          dexUrl: pair?.url || null,
        };
      });

    holdings.sort(
      (a, b) => b.valueUsd - a.valueUsd,
    );

    const activities = activityData.activities.map(
      (activity) => {
        const pair = activity.mint
          ? dex.get(activity.mint)
          : null;
        const priceUsd = n(pair?.priceUsd);

        return {
          ...activity,
          currentPriceUsd: priceUsd,
          currentDeltaValueUsd:
            Math.abs(activity.delta) * priceUsd,
        };
      },
    );

    const visibleTokenValueUsd = holdings.reduce(
      (sum, item) => sum + item.valueUsd,
      0,
    );

    const txCount = signatureList.length;
    const diversity = activityData.touched.size;

    const activityScore = Math.round(
      clamp(
        txCount * 7 +
          diversity * 9 +
          Math.min(
            25,
            Math.log10(
              visibleTokenValueUsd + 1,
            ) * 6,
          ),
      ),
    );

    const positionTier =
      visibleTokenValueUsd >= 25_000
        ? ("Large" as const)
        : visibleTokenValueUsd >= 2_500
          ? ("Medium" as const)
          : ("Small" as const);

    const report: WalletReport = {
      ok: true,
      address,
      solBalance:
        n(balanceResult?.value) / 1_000_000_000,
      visibleTokenValueUsd,
      holdings,
      recentActivity: activities,
      recentSignatureCount: txCount,
      distinctTokensTouched: diversity,
      activityScore,
      positionTier,
      rpcSource: customRpc
        ? "Custom Solana RPC"
        : "Solana public RPC",
      updatedAt: now,
      limitations: [
        "USD values use current DEX market prices, not historical entry prices.",
        "Visible token value only includes non-zero SPL Token accounts inspected in this stage and tokens with usable DEX pricing.",
        "Token-2022 accounts, NFTs, LP positions, staked assets, lending positions and off-chain balances can be missing.",
        "Activity score measures recent observable activity and portfolio visibility; it is not a profitability or smart-money score.",
        customRpc
          ? "Custom RPC is configured."
          : "Public Solana RPC is rate-limited and intended only for development.",
      ],
    };

    cache.set(address, {
      expiresAt: now + CACHE_MS,
      report,
    });

    return NextResponse.json(report, {
      headers: { "Cache-Control": "no-store" },
    });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error:
          error instanceof Error
            ? error.message
            : "Wallet analysis failed.",
      },
      {
        status: 502,
        headers: { "Cache-Control": "no-store" },
      },
    );
  }
}

