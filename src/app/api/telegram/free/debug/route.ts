import { NextResponse } from "next/server";

function authorized(request: Request) {
  const secret = process.env.CRON_SECRET?.trim() ?? "";
  return Boolean(
    secret &&
    request.headers.get("x-memescope-cron")?.trim() === secret
  );
}

export async function GET(request: Request) {
  if (!authorized(request)) {
    return NextResponse.json({ ok: false }, { status: 401 });
  }

  const base = "https://api.dexscreener.com";

  const sources = {
    boost: `${base}/token-boosts/latest/v1`,
    profile: `${base}/token-profiles/latest/v1`,
    cto: `${base}/community-takeovers/latest/v1`,
    ads: `${base}/ads/latest/v1`,
  };

  const results: Record<string, unknown> = {};

  for (const [name, url] of Object.entries(sources)) {
    try {
      const response = await fetch(url, {
        cache: "no-store",
        headers: { accept: "application/json" },
      });

      let body: unknown = null;

      try {
        body = await response.json();
      } catch {}

      const rows = Array.isArray(body) ? body : [];

      results[name] = {
        status: response.status,
        ok: response.ok,
        count: rows.length,
        solana: rows.filter(
          (x: any) => x?.chainId === "solana"
        ).length,
      };
    } catch (error) {
      results[name] = {
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      };
    }
  }

  return NextResponse.json({
    ok: true,
    sources: results,
  });
}
