import { NextRequest, NextResponse } from "next/server";
import type {
  OwnerConcentration,
  RiskFlag,
  SolanaRiskReport,
} from "@/lib/risk-types";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const PUBLIC_RPC = "https://api.mainnet.solana.com";
const CACHE_MS = 15_000;

const TOKEN_PROGRAM = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
const TOKEN_2022_PROGRAM = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb";

const cache = new Map<
  string,
  { expiresAt: number; report: SolanaRiskReport }
>();

type Json = Record<string, any>;

function number(value: unknown) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function clamp(value: number, min = 0, max = 100) {
  return Math.min(max, Math.max(min, value));
}

function shortProgram(program: string | null) {
  if (program === TOKEN_PROGRAM) return "SPL Token" as const;
  if (program === TOKEN_2022_PROGRAM) return "Token-2022" as const;
  return "Unknown" as const;
}

async function rpc(
  rpcUrl: string,
  method: string,
  params: unknown[],
  id: number,
) {
  const maxAttempts = 4;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
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

    if (response.status === 429) {
      const retryAfterHeader =
        response.headers.get("retry-after");

      const waitMs =
        retryAfterHeader &&
        Number.isFinite(Number(retryAfterHeader))
          ? Number(retryAfterHeader) * 1000
          : Math.min(8000, 750 * 2 ** (attempt - 1));

      if (attempt === maxAttempts) {
        throw new Error(
          "Solana RPC rate limit reached. Configure SOLANA_RPC_URL for stable real-time data.",
        );
      }

      await new Promise((resolve) =>
        setTimeout(resolve, waitMs),
      );

      continue;
    }

    if (!response.ok) {
      throw new Error(`Solana RPC ${response.status}`);
    }

    const data = (await response.json()) as Json;

    if (data.error) {
      throw new Error(
        data.error.message || `RPC ${method} returned an error`,
      );
    }

    return data.result;
  }

  throw new Error("Solana RPC request failed.");
}

async function fetchDexPairs(address: string) {
  const direct = await fetch(
    `https://api.dexscreener.com/token-pairs/v1/solana/${encodeURIComponent(address)}`,
    {
      headers: {
        Accept: "application/json",
        "User-Agent": "MemeScope/0.3",
      },
      cache: "no-store",
    },
  );

  if (direct.ok) {
    const data = await direct.json();
    if (Array.isArray(data)) return data as Json[];
  }

  const fallback = await fetch(
    `https://api.dexscreener.com/latest/dex/search?q=${encodeURIComponent(address)}`,
    {
      headers: {
        Accept: "application/json",
        "User-Agent": "MemeScope/0.3",
      },
      cache: "no-store",
    },
  );

  if (!fallback.ok) return [];

  const data = (await fallback.json()) as Json;
  return Array.isArray(data.pairs)
    ? data.pairs.filter(
        (pair: Json) =>
          String(pair.chainId).toLowerCase() === "solana" &&
          pair.baseToken?.address === address,
      )
    : [];
}

function marketFromPairs(pairs: Json[], now: number) {
  const best =
    [...pairs].sort(
      (a, b) =>
        number(b?.liquidity?.usd) - number(a?.liquidity?.usd),
    )[0] || null;

  if (!best) {
    return {
      pairAddress: null,
      dexId: null,
      dexUrl: null,
      name: null,
      symbol: null,
      priceUsd: 0,
      marketCap: 0,
      fdv: 0,
      liquidity: 0,
      liquidityToMarketCap: null,
      volume5m: 0,
      buys5m: 0,
      sells5m: 0,
      pairCreatedAt: null,
      pairAgeMinutes: null,
    };
  }

  const marketCap = number(best.marketCap ?? best.fdv);
  const liquidity = number(best?.liquidity?.usd);
  const createdAt =
    typeof best.pairCreatedAt === "number"
      ? best.pairCreatedAt
      : null;

  return {
    pairAddress: best.pairAddress || null,
    dexId: best.dexId || null,
    dexUrl: best.url || null,
    name: best.baseToken?.name || null,
    symbol: best.baseToken?.symbol || null,
    priceUsd: number(best.priceUsd),
    marketCap: number(best.marketCap),
    fdv: number(best.fdv),
    liquidity,
    liquidityToMarketCap:
      marketCap > 0 ? liquidity / marketCap : null,
    volume5m: number(best?.volume?.m5),
    buys5m: number(best?.txns?.m5?.buys),
    sells5m: number(best?.txns?.m5?.sells),
    pairCreatedAt: createdAt,
    pairAgeMinutes: createdAt
      ? Math.max(0, Math.floor((now - createdAt) / 60_000))
      : null,
  };
}

function buildRisk(
  input: {
    mintAuthorityDisabled: boolean | null;
    freezeAuthorityDisabled: boolean | null;
    top1: number;
    top10: number;
    market: ReturnType<typeof marketFromPairs>;
  },
) {
  const flags: RiskFlag[] = [];
  let score = 0;

  if (input.mintAuthorityDisabled === true) {
    flags.push({
      id: "mint-disabled",
      title: "Mint authority disabled",
      description:
        "No active mint authority was reported by the mint account.",
      severity: "good",
      points: 0,
    });
  } else if (input.mintAuthorityDisabled === false) {
    score += 25;
    flags.push({
      id: "mint-active",
      title: "Mint authority active",
      description:
        "The mint account still reports an authority capable of minting additional supply.",
      severity: "danger",
      points: 25,
    });
  } else {
    flags.push({
      id: "mint-unknown",
      title: "Mint authority unknown",
      description:
        "The RPC response could not be parsed well enough to verify mint authority.",
      severity: "warning",
      points: 0,
    });
  }

  if (input.freezeAuthorityDisabled === true) {
    flags.push({
      id: "freeze-disabled",
      title: "Freeze authority disabled",
      description:
        "No active freeze authority was reported by the mint account.",
      severity: "good",
      points: 0,
    });
  } else if (input.freezeAuthorityDisabled === false) {
    score += 20;
    flags.push({
      id: "freeze-active",
      title: "Freeze authority active",
      description:
        "The mint account still reports an authority that may freeze token accounts.",
      severity: "danger",
      points: 20,
    });
  } else {
    flags.push({
      id: "freeze-unknown",
      title: "Freeze authority unknown",
      description:
        "The RPC response could not be parsed well enough to verify freeze authority.",
      severity: "warning",
      points: 0,
    });
  }

  if (input.top1 > 20) {
    score += 20;
    flags.push({
      id: "top1-high",
      title: "Very high largest-owner concentration",
      description: `Largest observed owner controls about ${input.top1.toFixed(1)}% of supply.`,
      severity: "danger",
      points: 20,
    });
  } else if (input.top1 > 10) {
    score += 10;
    flags.push({
      id: "top1-medium",
      title: "Elevated largest-owner concentration",
      description: `Largest observed owner controls about ${input.top1.toFixed(1)}% of supply.`,
      severity: "warning",
      points: 10,
    });
  } else {
    flags.push({
      id: "top1-ok",
      title: "Largest observed owner below 10%",
      description: `Largest observed owner is about ${input.top1.toFixed(1)}% of supply.`,
      severity: "good",
      points: 0,
    });
  }

  if (input.top10 > 60) {
    score += 20;
    flags.push({
      id: "top10-high",
      title: "Very concentrated observed ownership",
      description: `Top observed owners account for about ${input.top10.toFixed(1)}% of supply.`,
      severity: "danger",
      points: 20,
    });
  } else if (input.top10 > 40) {
    score += 12;
    flags.push({
      id: "top10-medium",
      title: "Concentrated observed ownership",
      description: `Top observed owners account for about ${input.top10.toFixed(1)}% of supply.`,
      severity: "warning",
      points: 12,
    });
  } else if (input.top10 > 25) {
    score += 6;
    flags.push({
      id: "top10-watch",
      title: "Ownership concentration worth checking",
      description: `Top observed owners account for about ${input.top10.toFixed(1)}% of supply.`,
      severity: "info",
      points: 6,
    });
  } else {
    flags.push({
      id: "top10-ok",
      title: "Observed ownership relatively distributed",
      description: `Top observed owners account for about ${input.top10.toFixed(1)}% of supply.`,
      severity: "good",
      points: 0,
    });
  }

  const liquidity = input.market.liquidity;
  const ratio = input.market.liquidityToMarketCap;

  if (liquidity > 0 && liquidity < 10_000) {
    score += 15;
    flags.push({
      id: "liquidity-low",
      title: "Low DEX liquidity",
      description: `Best observed pair has only about $${Math.round(liquidity).toLocaleString("en-US")} of liquidity.`,
      severity: "danger",
      points: 15,
    });
  } else if (liquidity > 0 && liquidity < 30_000) {
    score += 7;
    flags.push({
      id: "liquidity-medium",
      title: "Thin DEX liquidity",
      description: `Best observed pair has about $${Math.round(liquidity).toLocaleString("en-US")} of liquidity.`,
      severity: "warning",
      points: 7,
    });
  }

  if (ratio !== null && ratio < 0.05) {
    score += 15;
    flags.push({
      id: "liq-ratio-low",
      title: "Very low liquidity-to-market-cap ratio",
      description: `Liquidity is roughly ${(ratio * 100).toFixed(1)}% of market cap/FDV.`,
      severity: "danger",
      points: 15,
    });
  } else if (ratio !== null && ratio < 0.1) {
    score += 9;
    flags.push({
      id: "liq-ratio-watch",
      title: "Low liquidity-to-market-cap ratio",
      description: `Liquidity is roughly ${(ratio * 100).toFixed(1)}% of market cap/FDV.`,
      severity: "warning",
      points: 9,
    });
  }

  const buys = input.market.buys5m;
  const sells = input.market.sells5m;

  if (sells > 10 && sells > buys * 2) {
    score += 10;
    flags.push({
      id: "sell-pressure",
      title: "Heavy short-term sell pressure",
      description: `5m transactions show ${buys} buys versus ${sells} sells.`,
      severity: "warning",
      points: 10,
    });
  }

  const age = input.market.pairAgeMinutes;

  if (age !== null && age < 30) {
    score += 8;
    flags.push({
      id: "very-new-pair",
      title: "Very new trading pair",
      description: "The best observed pair is less than 30 minutes old.",
      severity: "warning",
      points: 8,
    });
  } else if (age !== null && age < 120) {
    score += 4;
    flags.push({
      id: "new-pair",
      title: "New trading pair",
      description: "The best observed pair is less than two hours old.",
      severity: "info",
      points: 4,
    });
  }

  const finalScore = Math.round(clamp(score));

  return {
    score: finalScore,
    label:
      finalScore >= 61
        ? ("High" as const)
        : finalScore >= 31
          ? ("Moderate" as const)
          : ("Low" as const),
    flags,
  };
}

function sumPct(
  owners: OwnerConcentration[],
  count: number,
) {
  return owners
    .slice(0, count)
    .reduce((sum, item) => sum + item.percentage, 0);
}

export async function GET(
  _request: NextRequest,
  context: { params: Promise<{ address: string }> },
) {
  const { address } = await context.params;

  if (!/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(address)) {
    return NextResponse.json(
      { ok: false, error: "Invalid Solana token address." },
      { status: 400 },
    );
  }

  const cached = cache.get(address);
  if (cached && Date.now() < cached.expiresAt) {
    return NextResponse.json(cached.report, {
      headers: { "Cache-Control": "no-store" },
    });
  }

  const customRpc = process.env.SOLANA_RPC_URL?.trim();
  const rpcUrl = customRpc || PUBLIC_RPC;
  const now = Date.now();

  try {
    const [mintAccount, supplyResult, dexPairs] =
      await Promise.all([
        rpc(
          rpcUrl,
          "getAccountInfo",
          [
            address,
            {
              encoding: "jsonParsed",
              commitment: "confirmed",
            },
          ],
          1,
        ),
        rpc(
          rpcUrl,
          "getTokenSupply",
          [address, { commitment: "confirmed" }],
          2,
        ),
        fetchDexPairs(address),
      ]);

    let largestResult: Json = { value: [] };
    let concentrationAvailable = true;

    try {
      largestResult = await rpc(
        rpcUrl,
        "getTokenLargestAccounts",
        [address, { commitment: "confirmed" }],
        3,
      );
    } catch (error) {
      concentrationAvailable = false;

      console.warn(
        "[Risk Analyzer] Holder concentration unavailable:",
        error instanceof Error ? error.message : error,
      );
    }

    if (!mintAccount?.value) {
      throw new Error("Token mint account was not found.");
    }

    const mintValue = mintAccount.value as Json;
    const mintInfo = mintValue?.data?.parsed?.info as Json | undefined;

    const tokenProgram =
      typeof mintValue.owner === "string"
        ? mintValue.owner
        : null;

    const mintAuthority =
      mintInfo && "mintAuthority" in mintInfo
        ? mintInfo.mintAuthority ?? null
        : null;

    const freezeAuthority =
      mintInfo && "freezeAuthority" in mintInfo
        ? mintInfo.freezeAuthority ?? null
        : null;

    const mintAuthorityDisabled =
      mintInfo && "mintAuthority" in mintInfo
        ? mintAuthority === null
        : null;

    const freezeAuthorityDisabled =
      mintInfo && "freezeAuthority" in mintInfo
        ? freezeAuthority === null
        : null;

    const supply = number(
      supplyResult?.value?.uiAmountString ??
        supplyResult?.value?.uiAmount,
    );

    const largestAccounts = Array.isArray(largestResult?.value)
      ? largestResult.value.slice(0, 20)
      : [];

    const accountAddresses = largestAccounts
      .map((item: Json) => item.address)
      .filter(Boolean);

    let accountDetails: Json[] = [];

    if (accountAddresses.length > 0) {
      const multiple = await rpc(
        rpcUrl,
        "getMultipleAccounts",
        [
          accountAddresses,
          {
            encoding: "jsonParsed",
            commitment: "confirmed",
          },
        ],
        4,
      );

      accountDetails = Array.isArray(multiple?.value)
        ? multiple.value
        : [];
    }

    const ownerBalances = new Map<string, number>();

    largestAccounts.forEach((item: Json, index: number) => {
      const parsedOwner =
        accountDetails[index]?.data?.parsed?.info?.owner;
      const owner =
        typeof parsedOwner === "string"
          ? parsedOwner
          : item.address;

      const amount = number(
        item.uiAmountString ?? item.uiAmount,
      );

      ownerBalances.set(
        owner,
        (ownerBalances.get(owner) || 0) + amount,
      );
    });

    const topOwners: OwnerConcentration[] =
      Array.from(ownerBalances.entries())
        .map(([owner, amount]) => ({
          owner,
          amount,
          percentage:
            supply > 0 ? (amount / supply) * 100 : 0,
        }))
        .sort((a, b) => b.amount - a.amount);

    const top1 = sumPct(topOwners, 1);
    const top5 = sumPct(topOwners, 5);
    const top10 = sumPct(topOwners, 10);
    const market = marketFromPairs(dexPairs, now);

    const risk = buildRisk({
      mintAuthorityDisabled,
      freezeAuthorityDisabled,
      top1,
      top10,
      market,
    });

    if (!concentrationAvailable) {
      risk.flags = risk.flags.filter(
        (flag) =>
          flag.id !== "top1-ok" &&
          flag.id !== "top10-ok",
      );

      risk.flags.push({
        id: "holder-data-unavailable",
        title: "Holder concentration unavailable",
        description:
          "The RPC provider could not safely query holder concentration for this mint. Holder concentration is excluded from this analysis.",
        severity: "warning",
        points: 0,
      });
    }

    const report: SolanaRiskReport = {
      ok: true,
      tokenAddress: address,
      tokenProgram,
      tokenStandard: shortProgram(tokenProgram),
      mintAuthority,
      freezeAuthority,
      mintAuthorityDisabled,
      freezeAuthorityDisabled,
      decimals:
        typeof supplyResult?.value?.decimals === "number"
          ? supplyResult.value.decimals
          : null,
      supply,
      top1Percentage: top1,
      top5Percentage: top5,
      top10Percentage: top10,
      analyzedOwnerCount: topOwners.length,
      topOwners: topOwners.slice(0, 10),
      riskScore: risk.score,
      riskLabel: risk.label,
      flags: risk.flags,
      market,
      rpcSource: customRpc
        ? "Custom Solana RPC"
        : "Solana public RPC",
      updatedAt: now,
      limitations: [
        concentrationAvailable
          ? "Largest-account concentration is derived from the 20 largest SPL token accounts returned by RPC and aggregated by parsed owner."
          : "Holder concentration could not be retrieved for this mint because the RPC provider rejected the large-account query. Concentration is not treated as safe or unsafe.",
        "DEX/AMM vaults, bonding-curve accounts, exchanges or program-owned token accounts can appear in concentration figures and should not automatically be interpreted as one human whale.",
        "LP lock/burn status, deployer history, bundled launches and sniper-wallet attribution are not claimed in this stage.",
        customRpc
          ? "Custom RPC is configured."
          : "The public Solana RPC is suitable for development but is rate-limited and is not intended for production traffic.",
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
            : "Risk analysis failed.",
      },
      {
        status: 502,
        headers: { "Cache-Control": "no-store" },
      },
    );
  }
}
