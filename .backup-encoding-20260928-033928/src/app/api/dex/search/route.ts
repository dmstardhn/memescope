import { NextRequest, NextResponse } from "next/server";

export const dynamic = "force-dynamic";

export async function GET(request: NextRequest) {
  const q = request.nextUrl.searchParams.get("q")?.trim();

  if (!q || q.length < 2) {
    return NextResponse.json(
      { error: "Query must contain at least 2 characters." },
      { status: 400 },
    );
  }

  try {
    const response = await fetch(
      `https://api.dexscreener.com/latest/dex/search?q=${encodeURIComponent(q)}`,
      {
        headers: {
          Accept: "application/json",
        },
        cache: "no-store",
      },
    );

    if (!response.ok) {
      return NextResponse.json(
        { error: `Dexscreener returned ${response.status}` },
        { status: 502 },
      );
    }

    const data = await response.json();

    return NextResponse.json({
      pairs: Array.isArray(data.pairs) ? data.pairs : [],
    });
  } catch {
    return NextResponse.json(
      { error: "Unable to reach Dexscreener." },
      { status: 502 },
    );
  }
}
