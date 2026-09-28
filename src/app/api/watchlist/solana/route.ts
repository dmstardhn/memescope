import { NextRequest, NextResponse } from "next/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type Json = Record<string, any>;

function n(value: unknown) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function validAddress(address: string) {
  return /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(address);
}

export async function GET(request: NextRequest) {
  const raw =
    request.nextUrl.searchParams.get("addresses") || "";

  const addresses = Array.from(
    new Set(
      raw
        .split(",")
        .map((item) => item.trim())
        .filter(validAddress),
    ),
  ).slice(0, 30);

  if (!addresses.length) {
    return NextResponse.json({
      ok: true,
      updatedAt: Date.now(),
      tokens: [],
    });
  }

  try {
    const joined = addresses
      .map((address) => encodeURIComponent(address))
      .join(",");

    const response = await fetch(
      `https://api.dexscreener.com/tokens/v1/solana/${joined}`,
      {
        headers: {
          Accept: "application/json",
          "User-Agent": "MemeScope/0.5.1",
        },
        cache: "no-store",
      },
    );

    if (!response.ok) {
      throw new Error(
        `DEX Screener returned ${response.status}`,
      );
    }

    const data = await response.json();

    const pairs: Json[] = Array.isArray(data)
      ? data
      : Array.isArray(data?.pairs)
        ? data.pairs
        : [];

    const best = new Map<string, Json>();

    for (const pair of pairs) {
      const address = pair?.baseToken?.address;

      if (!address || !addresses.includes(address)) {
        continue;
      }

      const existing = best.get(address);
      const oldLiquidity = n(
        existing?.liquidity?.usd,
      );
      const newLiquidity = n(
        pair?.liquidity?.usd,
      );

      if (!existing || newLiquidity > oldLiquidity) {
        best.set(address, pair);
      }
    }

    const tokens = addresses.map((address) => {
      const pair = best.get(address);

      return {
        address,
        found: Boolean(pair),
        name: pair?.baseToken?.name || null,
        symbol: pair?.baseToken?.symbol || null,
        imageUrl: pair?.info?.imageUrl || null,
        dexId: pair?.dexId || null,
        dexUrl: pair?.url || null,
        pairAddress: pair?.pairAddress || null,
        priceUsd: n(pair?.priceUsd),
        marketCap: n(
          pair?.marketCap ?? pair?.fdv,
        ),
        liquidity: n(
          pair?.liquidity?.usd,
        ),
        volume5m: n(pair?.volume?.m5),
        buys5m: n(pair?.txns?.m5?.buys),
        sells5m: n(pair?.txns?.m5?.sells),
        priceChange5m: n(
          pair?.priceChange?.m5,
        ),
      };
    });

    return NextResponse.json(
      {
        ok: true,
        updatedAt: Date.now(),
        tokens,
      },
      {
        headers: {
          "Cache-Control": "no-store",
        },
      },
    );
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        updatedAt: Date.now(),
        tokens: [],
        error:
          error instanceof Error
            ? error.message
            : "Watchlist market lookup failed.",
      },
      {
        status: 502,
        headers: {
          "Cache-Control": "no-store",
        },
      },
    );
  }
}
