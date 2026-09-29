$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Get-Location).Path

if (!(Test-Path -LiteralPath (Join-Path $root "package.json"))) {
    throw "Run this script from the memecoin-analyst project root."
}

$path = Join-Path $root "src\lib\content-hq.ts"

if (!(Test-Path -LiteralPath $path)) {
    throw "Missing file: src/lib/content-hq.ts"
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $env:TEMP "MemeScope-MatrixDemo-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-Item -LiteralPath $path -Destination (Join-Path $backupDir "content-hq.ts") -Force

$utf8 = New-Object System.Text.UTF8Encoding($false)
$content = [System.IO.File]::ReadAllText($path)

# ------------------------------------------------------------
# 1. Allow demo code to force a visual source.
# ------------------------------------------------------------

$oldSignature = @'
async function createQueueItem(
  candidate:
    ContentCandidate,
  config:
    ContentConfig,
) {
'@

$newSignature = @'
async function createQueueItem(
  candidate:
    ContentCandidate,
  config:
    ContentConfig,
  forcedSource?:
    VisualSource,
) {
'@

if ($content.Contains($oldSignature)) {
    $content = $content.Replace($oldSignature, $newSignature)
}
elseif (!$content.Contains("forcedSource?:")) {
    throw "createQueueItem signature marker not found. No file was changed."
}

$oldSource = @'
  const source =
    await chooseSource(
      candidate.contentType,
      config,
    );
'@

$newSource = @'
  const source =
    forcedSource ??
    (await chooseSource(
      candidate.contentType,
      config,
    ));
'@

if ($content.Contains($oldSource)) {
    $content = $content.Replace($oldSource, $newSource)
}
elseif (!$content.Contains("forcedSource ??")) {
    throw "createQueueItem source marker not found. No file was changed."
}

# ------------------------------------------------------------
# 2. Add a large multi-platform demo matrix.
# ------------------------------------------------------------

if (!$content.Contains("export async function contentHqDemoScenarioCount(")) {
$append = @'

type ContentHqDemoScenario = {
  source: VisualSource;
  contentType: ContentType;
  multiple: number;
  label: string;
};

const CONTENT_HQ_DEMO_SCENARIOS:
  ContentHqDemoScenario[] = [
    {
      source: "dex_screener",
      contentType: "new_discovery",
      multiple: 1.18,
      label: "DEX New Discovery A",
    },
    {
      source: "dex_screener",
      contentType: "new_discovery",
      multiple: 1.31,
      label: "DEX New Discovery B",
    },
    {
      source: "dex_screener",
      contentType: "runner",
      multiple: 2.08,
      label: "DEX Runner A",
    },
    {
      source: "dex_screener",
      contentType: "runner",
      multiple: 2.46,
      label: "DEX Runner B",
    },
    {
      source: "dex_screener",
      contentType: "big_runner",
      multiple: 4.12,
      label: "DEX Big Runner A",
    },
    {
      source: "dex_screener",
      contentType: "big_runner",
      multiple: 4.73,
      label: "DEX Big Runner B",
    },
    {
      source: "dex_screener",
      contentType: "moonshot",
      multiple: 6.18,
      label: "DEX Moonshot A",
    },
    {
      source: "dex_screener",
      contentType: "moonshot",
      multiple: 8.35,
      label: "DEX Moonshot B",
    },
    {
      source: "dex_screener",
      contentType: "before_move",
      multiple: 3.18,
      label: "DEX Before The Move A",
    },
    {
      source: "dex_screener",
      contentType: "before_move",
      multiple: 5.42,
      label: "DEX Before The Move B",
    },

    {
      source: "gmgn",
      contentType: "wallet_activity",
      multiple: 1.22,
      label: "GMGN Wallet Activity A",
    },
    {
      source: "gmgn",
      contentType: "wallet_activity",
      multiple: 1.41,
      label: "GMGN Wallet Activity B",
    },
    {
      source: "gmgn",
      contentType: "wallet_activity",
      multiple: 1.67,
      label: "GMGN Wallet Activity C",
    },
    {
      source: "gmgn",
      contentType: "holder_growth",
      multiple: 1.16,
      label: "GMGN Holder Growth A",
    },
    {
      source: "gmgn",
      contentType: "holder_growth",
      multiple: 1.34,
      label: "GMGN Holder Growth B",
    },
    {
      source: "gmgn",
      contentType: "holder_growth",
      multiple: 1.58,
      label: "GMGN Holder Growth C",
    },
    {
      source: "gmgn",
      contentType: "new_discovery",
      multiple: 1.27,
      label: "GMGN Discovery",
    },
    {
      source: "gmgn",
      contentType: "runner",
      multiple: 2.19,
      label: "GMGN Runner",
    },

    {
      source: "memescope",
      contentType: "memescope_detection",
      multiple: 1.24,
      label: "MemeScope Detection A",
    },
    {
      source: "memescope",
      contentType: "memescope_detection",
      multiple: 1.52,
      label: "MemeScope Detection B",
    },
    {
      source: "memescope",
      contentType: "memescope_detection",
      multiple: 1.81,
      label: "MemeScope Detection C",
    },
    {
      source: "memescope",
      contentType: "runner",
      multiple: 2.14,
      label: "MemeScope Runner A",
    },
    {
      source: "memescope",
      contentType: "runner",
      multiple: 2.63,
      label: "MemeScope Runner B",
    },
    {
      source: "memescope",
      contentType: "big_runner",
      multiple: 4.31,
      label: "MemeScope Big Runner",
    },
    {
      source: "memescope",
      contentType: "moonshot",
      multiple: 6.72,
      label: "MemeScope Moonshot",
    },
    {
      source: "memescope",
      contentType: "before_move",
      multiple: 3.64,
      label: "MemeScope Before The Move",
    },
    {
      source: "memescope",
      contentType: "weekly_recap",
      multiple: 1,
      label: "MemeScope Weekly Recap A",
    },
    {
      source: "memescope",
      contentType: "weekly_recap",
      multiple: 1,
      label: "MemeScope Weekly Recap B",
    },

    {
      source: "text_only",
      contentType: "text_only",
      multiple: 1,
      label: "Text Only A",
    },
    {
      source: "text_only",
      contentType: "text_only",
      multiple: 1,
      label: "Text Only B",
    },
    {
      source: "text_only",
      contentType: "text_only",
      multiple: 1,
      label: "Text Only C",
    },
    {
      source: "text_only",
      contentType: "text_only",
      multiple: 1,
      label: "Text Only D",
    },
  ];

export async function contentHqDemoScenarioCount() {
  return CONTENT_HQ_DEMO_SCENARIOS.length;
}

async function weeklyDemoCaption(
  symbol: string,
  variant: number,
) {
  const sql = sqlClient();

  const rows = await sql`
    SELECT
      COUNT(*)::INTEGER AS total_calls,
      COUNT(*) FILTER (
        WHERE peak_multiple >= 2
      )::INTEGER AS reached_2x,
      COUNT(*) FILTER (
        WHERE peak_multiple >= 5
      )::INTEGER AS reached_5x
    FROM memescope_call_story
    WHERE called_at >= NOW() - INTERVAL '7 days'
  `;

  const row =
    (rows[0] ??
      {}) as DbRow;

  const total =
    num(
      row.total_calls,
      0,
    );

  const twoX =
    num(
      row.reached_2x,
      0,
    );

  const fiveX =
    num(
      row.reached_5x,
      0,
    );

  if (variant % 2 === 0) {
    return [
      "this week",
      "",
      `${total} tokens tracked`,
      `${twoX} passed 2x`,
      `${fiveX} passed 5x`,
    ].join("\n");
  }

  return [
    "weekly tape.",
    "",
    `${total} calls tracked.`,
    `${twoX} reached 2x.`,
    `${fiveX} reached 5x.`,
    "",
    `top of the queue right now: $${symbol}`,
  ].join("\n");
}

export async function createContentHqMatrixDemo(
  scenarioIndex: number,
) {
  await ensureContentHqSchema();

  if (
    !Number.isInteger(
      scenarioIndex,
    ) ||
    scenarioIndex < 0 ||
    scenarioIndex >=
      CONTENT_HQ_DEMO_SCENARIOS.length
  ) {
    throw new Error(
      "Invalid demo scenario index.",
    );
  }

  const scenario =
    CONTENT_HQ_DEMO_SCENARIOS[
      scenarioIndex
    ];

  const sql = sqlClient();
  const config =
    await getContentConfig();

  const rows = await sql`
    SELECT *
    FROM memescope_call_story
    WHERE token_address IS NOT NULL
      AND token_address <> ''
    ORDER BY called_at DESC
    LIMIT 60
  `;

  if (!rows.length) {
    throw new Error(
      "No MemeScope calls are available for the demo matrix.",
    );
  }

  const uniqueRows:
    DbRow[] = [];

  const seen =
    new Set<string>();

  for (const raw of rows) {
    const row =
      raw as DbRow;

    const address =
      str(
        row.token_address,
      );

    if (
      !address ||
      seen.has(address)
    ) {
      continue;
    }

    seen.add(address);
    uniqueRows.push(row);
  }

  const sourceRows =
    uniqueRows.length
      ? uniqueRows
      : rows.map(
          (row) =>
            row as DbRow,
        );

  const row =
    sourceRows[
      scenarioIndex %
      sourceRows.length
    ];

  const base =
    await candidateFromCall(
      row,
      {
        ...config,
        minLiquidityUsd: 0,
        minVolumeUsd: 0,
        maxTokenAgeHours:
          1_000_000,
      },
    );

  if (!base) {
    throw new Error(
      "The selected call could not be converted into a demo candidate.",
    );
  }

  const currentMarketCap =
    base.firstMarketCap ===
    null
      ? base.currentMarketCap
      : base.firstMarketCap *
        scenario.multiple;

  const candidate:
    ContentCandidate = {
    ...base,
    eventKey:
      `demo:matrix:${Date.now()}:${scenarioIndex}:${base.tokenAddress}`,
    contentType:
      scenario.contentType,
    priority:
      PRIORITY[
        scenario.contentType
      ],
    currentMarketCap,
    gainPct:
      Math.max(
        0,
        (
          scenario.multiple -
          1
        ) * 100,
      ),
    multiple:
      scenario.multiple,
    milestone:
      scenario.multiple > 1
        ? `${scenario.multiple.toFixed(
            2,
          )}X`
        : null,
    detectedAt:
      base.detectedAt,
  };

  const item =
    await createQueueItem(
      candidate,
      {
        ...config,
        manualApproval: true,
        minLiquidityUsd: 0,
        minVolumeUsd: 0,
        maxTokenAgeHours:
          1_000_000,
        tokenPostCooldownMinutes: 0,
      },
      scenario.source,
    );

  if (!item) {
    throw new Error(
      "Demo matrix item was not created.",
    );
  }

  let finalItem =
    item;

  if (
    scenario.contentType ===
    "weekly_recap"
  ) {
    const caption =
      await weeklyDemoCaption(
        item.symbol,
        scenarioIndex,
      );

    await sql`
      UPDATE memescope_content_queue
      SET
        caption = ${caption},
        updated_at = NOW()
      WHERE id = ${item.id}
    `;

    const refreshed =
      await getQueueItem(
        item.id,
      );

    if (refreshed) {
      finalItem =
        refreshed;
    }
  }

  const previewMessageId =
    await sendQueuePreview(
      finalItem,
    );

  const media =
    await getQueueMedia(
      finalItem.id,
    );

  return {
    scenarioIndex,
    totalScenarios:
      CONTENT_HQ_DEMO_SCENARIOS.length,
    label:
      scenario.label,
    source:
      scenario.source,
    contentType:
      scenario.contentType,
    symbol:
      finalItem.symbol,
    tokenAddress:
      finalItem.tokenAddress,
    captionTemplate:
      finalItem.captionTemplate,
    screenshotPreset:
      finalItem.screenshotPreset,
    mediaGenerated:
      Boolean(media),
    previewMessageId,
  };
}
'@

$content += $append
}

[System.IO.File]::WriteAllText($path, $content, $utf8)

# ------------------------------------------------------------
# 3. Demo route: one scenario per request, keeping each Vercel
#    invocation small and avoiding a 30-screenshot timeout.
# ------------------------------------------------------------

$routeDir = Join-Path $root "src\app\api\content-hq\matrix-demo"
New-Item -ItemType Directory -Force -Path $routeDir | Out-Null

$route = @'
import {
  NextResponse,
} from "next/server";

import {
  contentHqDemoScenarioCount,
  createContentHqMatrixDemo,
} from "@/lib/content-hq";

function authorized(
  request: Request,
) {
  const secret =
    process.env
      .CRON_SECRET
      ?.trim();

  return Boolean(
    secret &&
      request.headers.get(
        "authorization",
      ) ===
        `Bearer ${secret}`,
  );
}

export async function GET(
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

  return NextResponse.json({
    ok: true,
    count:
      await contentHqDemoScenarioCount(),
  });
}

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

  const body =
    (await request
      .json()
      .catch(
        () => ({}),
      )) as {
      index?: number;
    };

  const index =
    Number(
      body.index,
    );

  try {
    const result =
      await createContentHqMatrixDemo(
        index,
      );

    return NextResponse.json({
      ok: true,
      demo: true,
      ...result,
    });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error:
          error instanceof Error
            ? error.message
            : "Matrix demo failed.",
      },
      {
        status: 500,
      },
    );
  }
}
'@

[System.IO.File]::WriteAllText(
    (Join-Path $routeDir "route.ts"),
    $route,
    $utf8
)

Write-Host ""
Write-Host "Large Content HQ matrix demo installed." -ForegroundColor Green
Write-Host "Scenarios: 32" -ForegroundColor Cyan
Write-Host ""
Write-Host "Coverage:" -ForegroundColor Cyan
Write-Host " DEX Screener : 10 demos"
Write-Host " GMGN         : 8 demos"
Write-Host " MemeScope    : 10 demos"
Write-Host " Text-only    : 4 demos"
Write-Host ""
Write-Host "The scenarios use different recent MemeScope tokens when available." -ForegroundColor Yellow
Write-Host "No demo is published to X." -ForegroundColor Yellow
Write-Host "Backup: $backupDir" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next:" -ForegroundColor Yellow
Write-Host " npm run typecheck"
Write-Host " npm run build"
