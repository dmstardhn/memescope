$ErrorActionPreference = "Stop"

$root = (Get-Location).Path
if (!(Test-Path -LiteralPath (Join-Path $root "package.json"))) {
    throw "Jalankan dari root project memecoin-analyst."
}

$dir = Join-Path $root "src\app\api\telegram\content-demo"
$path = Join-Path $dir "route.ts"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

if (Test-Path -LiteralPath $path) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Copy-Item -LiteralPath $path -Destination "$path.$stamp.bak" -Force
}

$content = @'
import {
  NextResponse,
} from "next/server";

import {
  getContentHqStatus,
} from "@/lib/call-story";
import {
  telegramSendMessage,
} from "@/lib/telegram";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function authorized(
  request: Request,
) {
  const secret =
    process.env.CRON_SECRET?.trim();

  return Boolean(
    secret &&
      request.headers.get(
        "authorization",
      ) === `Bearer ${secret}`,
  );
}

const DEMOS = [
  [
    "🧪 <b>DEMO — FAST RUNNER</b>",
    "",
    "🚀 <b>CONTENT OPPORTUNITY</b>",
    "",
    "<b>$FROG</b> reached <b>2.08X</b> from the MemeScope call.",
    "",
    "<b>CALL MC</b>",
    "$84K",
    "",
    "<b>PEAK MC</b>",
    "$175K",
    "",
    "<b>TIME TO 2X</b>",
    "38m",
    "",
    "<b>SIGNAL SCORE</b>",
    "88 / 100",
    "",
    "<b>MAX DRAWDOWN</b>",
    "-6.8%",
    "",
    "<b>CONTENT PRIORITY</b>",
    "⚡ MEDIUM",
    "",
    "<b>Suggested X Hook</b>",
    "",
    "<i>MemeScope flagged $FROG at $84K MC.",
    "38 minutes later, it crossed $175K.</i>",
    "",
    "MS-DEMO-001",
  ].join("\n"),

  [
    "🧪 <b>DEMO — MAJOR CALL</b>",
    "",
    "🔥 <b>HIGH PRIORITY CONTENT</b>",
    "",
    "<b>$PEPEAI</b> reached <b>5.22X</b> from the original MemeScope call.",
    "",
    "<b>CALL MC</b>",
    "$82K",
    "",
    "<b>PEAK MC</b>",
    "$428K",
    "",
    "<b>TIME TO 2X</b>",
    "1h 18m",
    "",
    "<b>TIME TO 5X</b>",
    "9h 42m",
    "",
    "<b>MAX DRAWDOWN</b>",
    "-9.4%",
    "",
    "<b>SIGNAL SCORE</b>",
    "91 / 100",
    "",
    "<b>Suggested X Hook</b>",
    "",
    "<i>MemeScope flagged $PEPEAI at $82K MC.",
    "It later reached $428K.</i>",
    "",
    "5.22X from the original call.",
    "",
    "<b>Suggested Content</b>",
    "• Result Story",
    "• Before The Move",
    "• Call Journey",
    "",
    "MS-DEMO-002",
  ].join("\n"),

  [
    "🧪 <b>DEMO — BEFORE THE MOVE</b>",
    "",
    "🔎 <b>CONTENT ANGLE</b>",
    "",
    "<b>What MemeScope saw before $PEPEAI moved from $82K → $428K</b>",
    "",
    "Buy Pressure",
    "<b>78%</b>",
    "",
    "Volume Expansion",
    "<b>2.9X</b>",
    "",
    "Liquidity",
    "<b>$61K</b>",
    "",
    "5m Momentum",
    "<b>+8.4%</b>",
    "",
    "Signal Score",
    "<b>91 / 100</b>",
    "",
    "<b>Suggested Headline</b>",
    "",
    "<i>What MemeScope saw before $PEPEAI went from $82K to $428K.</i>",
    "",
    "MS-DEMO-002",
  ].join("\n"),

  [
    "🧪 <b>DEMO — EXCEPTIONAL CALL</b>",
    "",
    "👑 <b>FEATURED CONTENT</b>",
    "",
    "<b>$DOGEX</b>",
    "",
    "<b>$74K → $768K</b>",
    "",
    "Peak Performance",
    "<b>10.38X</b>",
    "",
    "<b>CALL JOURNEY</b>",
    "",
    "CALL  —  $74K MC",
    "2X    —  41m",
    "5X    —  3h 26m",
    "10X   —  14h 12m",
    "",
    "<b>MAX DRAWDOWN</b>",
    "-12.1%",
    "",
    "<b>SIGNAL SCORE</b>",
    "93 / 100",
    "",
    "MS-DEMO-003",
  ].join("\n"),

  [
    "🧪 <b>DEMO — SPECIAL STORY</b>",
    "",
    "⚡ <b>SPECIAL CONTENT OPPORTUNITY</b>",
    "",
    "<b>$MOON</b> became one of MemeScope's strongest recorded calls.",
    "",
    "<b>CALL MC</b>",
    "$46K",
    "",
    "<b>PEAK MC</b>",
    "$2.34M",
    "",
    "<b>PEAK PERFORMANCE</b>",
    "50.87X",
    "",
    "<b>Suggested Hook</b>",
    "",
    "<i>MemeScope flagged $MOON at $46K MC.",
    "At its peak, it reached $2.34M.</i>",
    "",
    "Admin review recommended.",
    "",
    "MS-DEMO-004",
  ].join("\n"),

  [
    "🧪 <b>DEMO — DAILY TAPE</b>",
    "",
    "📊 <b>MEMESCOPE DAILY TAPE</b>",
    "",
    "29 SEP 2026",
    "",
    "<b>CALLS TODAY</b>",
    "7",
    "",
    "<b>2X RUNNERS</b>",
    "2",
    "",
    "<b>5X CALLS</b>",
    "1",
    "",
    "<b>TOP RECORDED CALL</b>",
    "$PEPEAI — 5.22X",
    "",
    "<b>FASTEST 2X</b>",
    "$FROG — 38m",
    "",
    "<b>CALLS STILL TRACKING</b>",
    "4",
  ].join("\n"),

  [
    "🧪 <b>DEMO — WEEKLY INTELLIGENCE</b>",
    "",
    "📈 <b>MEMESCOPE WEEKLY INTELLIGENCE</b>",
    "",
    "23 — 29 SEP 2026",
    "",
    "<b>TOTAL CALLS</b>",
    "42",
    "",
    "<b>REACHED 2X</b>",
    "9",
    "",
    "<b>REACHED 5X</b>",
    "3",
    "",
    "<b>REACHED 10X</b>",
    "1",
    "",
    "<b>TOP RECORDED CALL</b>",
    "$DOGEX — 10.38X",
    "",
    "<b>MEDIAN PEAK</b>",
    "1.58X",
    "",
    "<b>MEDIAN MAX DRAWDOWN</b>",
    "-14.2%",
  ].join("\n"),
];

export async function POST(
  request: Request,
) {
  if (!authorized(request)) {
    return NextResponse.json(
      {
        ok: false,
        error: "Unauthorized.",
      },
      {
        status: 401,
      },
    );
  }

  const hq =
    await getContentHqStatus();

  if (
    !hq.configured ||
    !hq.chatId
  ) {
    return NextResponse.json(
      {
        ok: false,
        error:
          "Content HQ is not connected.",
      },
      {
        status: 409,
      },
    );
  }

  const results = [];

  for (const text of DEMOS) {
    const message =
      await telegramSendMessage(
        hq.chatId,
        text,
      );

    results.push(
      message.message_id,
    );
  }

  return NextResponse.json({
    ok: true,
    delivered: results.length,
    chatId: hq.chatId,
    messageIds: results,
    note:
      "Demo only. No signal or call-history database rows were created.",
  });
}
'@

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($path, $content, $utf8)

Write-Host ""
Write-Host "Created: src/app/api/telegram/content-demo/route.ts" -ForegroundColor Green
Write-Host "This endpoint uses Vercel's server-side TELEGRAM_BOT_TOKEN." -ForegroundColor Cyan
Write-Host "It is protected by CRON_SECRET and sends only demo messages to the bound Content HQ." -ForegroundColor Cyan
Write-Host ""
Write-Host "Next:" -ForegroundColor Yellow
Write-Host " npm run typecheck"
Write-Host " npm run build"
