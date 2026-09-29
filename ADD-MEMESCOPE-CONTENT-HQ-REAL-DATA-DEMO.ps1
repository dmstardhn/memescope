$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Get-Location).Path
if (!(Test-Path -LiteralPath (Join-Path $root "package.json"))) {
    throw "Run this script from the memecoin-analyst project root."
}

$path = Join-Path $root "src\lib\content-hq.ts"
if (!(Test-Path -LiteralPath $path)) {
    throw "Missing file: $path"
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $env:TEMP "MemeScope-ContentHQ-Demo-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-Item -LiteralPath $path -Destination (Join-Path $backupDir "content-hq.ts") -Force

$content = [System.IO.File]::ReadAllText($path)

if ($content.Contains("export async function createContentHqDemo(")) {
    Write-Host "Demo helper already exists." -ForegroundColor DarkGray
}
else {
    $append = @'

export async function createContentHqDemo(
  kind:
    | "runner"
    | "big_runner"
    | "moonshot"
    | "before_move",
) {
  await ensureContentHqSchema();

  const config =
    await getContentConfig();

  const sql = sqlClient();

  const rows = await sql`
    SELECT *
    FROM memescope_call_story
    WHERE token_address IS NOT NULL
      AND token_address <> ''
    ORDER BY called_at DESC
    LIMIT 1
  `;

  if (!rows.length) {
    throw new Error(
      "No MemeScope call is available for a real screenshot demo.",
    );
  }

  const base =
    await candidateFromCall(
      rows[0] as DbRow,
      {
        ...config,
        minLiquidityUsd: 0,
        maxTokenAgeHours:
          1_000_000,
      },
    );

  if (!base) {
    throw new Error(
      "Latest MemeScope call could not be converted into a content candidate.",
    );
  }

  const multipleByKind = {
    runner: 2.15,
    big_runner: 4.25,
    moonshot: 6.10,
    before_move: 2.75,
  } as const;

  const multiple =
    multipleByKind[kind];

  const currentMarketCap =
    base.firstMarketCap === null
      ? base.currentMarketCap
      : base.firstMarketCap *
        multiple;

  const candidate:
    ContentCandidate = {
    ...base,
    eventKey:
      `demo:${Date.now()}:${base.tokenAddress}:${kind}`,
    contentType: kind,
    priority:
      PRIORITY[kind],
    currentMarketCap,
    gainPct:
      (multiple - 1) *
      100,
    multiple,
    milestone:
      `${multiple.toFixed(
        2,
      )}X`,
    detectedAt:
      new Date().toISOString(),
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
    );

  if (!item) {
    throw new Error(
      "Demo content was not created.",
    );
  }

  const previewMessageId =
    await sendQueuePreview(
      item,
    );

  return {
    itemId:
      item.id,
    contentType:
      item.contentType,
    symbol:
      item.symbol,
    source:
      item.visualSource,
    screenshotPreset:
      item.screenshotPreset,
    captionTemplate:
      item.captionTemplate,
    previewMessageId,
  };
}
'@

    $content += $append

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $content, $utf8)

    Write-Host "Added createContentHqDemo() to src/lib/content-hq.ts" -ForegroundColor Green
}

$routeDir = Join-Path $root "src\app\api\content-hq\demo"
New-Item -ItemType Directory -Force -Path $routeDir | Out-Null
$routePath = Join-Path $routeDir "route.ts"

$route = @'
import {
  NextResponse,
} from "next/server";

import {
  createContentHqDemo,
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
      ) === `Bearer ${secret}`,
  );
}

export async function POST(
  request: Request,
) {
  if (!authorized(request)) {
    return NextResponse.json(
      {
        ok: false,
        error:
          "Unauthorized.",
      },
      {
        status: 401,
      },
    );
  }

  const body =
    (await request.json()
      .catch(
        () => ({}),
      )) as {
      kind?: string;
    };

  const kind =
    body.kind;

  if (
    kind !== "runner" &&
    kind !== "big_runner" &&
    kind !== "moonshot" &&
    kind !== "before_move"
  ) {
    return NextResponse.json(
      {
        ok: false,
        error:
          "kind must be runner, big_runner, moonshot, or before_move.",
      },
      {
        status: 400,
      },
    );
  }

  try {
    const result =
      await createContentHqDemo(
        kind,
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
            : "Content HQ demo failed.",
      },
      {
        status: 500,
      },
    );
  }
}
'@

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($routePath, $route, $utf8)

Write-Host "Created: src/app/api/content-hq/demo/route.ts" -ForegroundColor Green
Write-Host "Backup: $backupDir" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next:" -ForegroundColor Yellow
Write-Host " npm run typecheck"
Write-Host " npm run build"
