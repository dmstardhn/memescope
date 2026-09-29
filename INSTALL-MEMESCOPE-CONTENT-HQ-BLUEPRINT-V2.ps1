$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " MemeScope Content HQ - Blueprint V2" -ForegroundColor Cyan
Write-Host " Deterministic / Rule-Based / Zero AI" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$root = (Get-Location).Path
if (!(Test-Path -LiteralPath (Join-Path $root "package.json"))) {
    throw "Run this installer from the memecoin-analyst project root."
}

$required = @(
    "src\lib\call-story.ts",
    "src\lib\telegram.ts",
    "src\app\api\telegram\cron\route.ts",
    "src\app\api\telegram\webhook\route.ts"
)

foreach ($relative in $required) {
    if (!(Test-Path -LiteralPath (Join-Path $root $relative))) {
        throw "Required project file is missing: $relative"
    }
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $env:TEMP "MemeScope-ContentHQ-BlueprintV2-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $path = Join-Path $root $RelativePath
    $parent = Split-Path -Parent $path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    if (Test-Path -LiteralPath $path) {
        $backupPath = Join-Path $backupDir $RelativePath
        $backupParent = Split-Path -Parent $backupPath
        New-Item -ItemType Directory -Force -Path $backupParent | Out-Null
        Copy-Item -LiteralPath $path -Destination $backupPath -Force
    }

    [System.IO.File]::WriteAllText($path, $Content, $utf8)
    Write-Host "Updated: $RelativePath" -ForegroundColor Green
}

Write-Host "Installing screenshot / image / X dependencies..." -ForegroundColor Cyan
npm install playwright-core @sparticuz/chromium sharp twitter-api-v2
if ($LASTEXITCODE -ne 0) {
    throw "npm install failed."
}

# ============================================================
# TYPES
# ============================================================

$types = @'
export type ContentType =
  | "new_discovery"
  | "runner"
  | "big_runner"
  | "moonshot"
  | "before_move"
  | "wallet_activity"
  | "holder_growth"
  | "memescope_detection"
  | "weekly_recap"
  | "text_only";

export type VisualSource =
  | "dex_screener"
  | "gmgn"
  | "memescope"
  | "text_only";

export type QueueStatus =
  | "draft"
  | "queued"
  | "approved"
  | "scheduled"
  | "published"
  | "failed"
  | "rejected";

export type ScreenshotPreset =
  | "dex_chart"
  | "dex_chart_metrics"
  | "dex_full_token"
  | "dex_before_after"
  | "gmgn_overview"
  | "gmgn_holders"
  | "gmgn_wallet"
  | "gmgn_activity"
  | "memescope_token"
  | "weekly_recap"
  | "none";

export type ContentConfig = {
  runnerGainPct: number;
  bigRunnerGainPct: number;
  moonshotGainPct: number;
  beforeMoveGainPct: number;
  minLiquidityUsd: number;
  minVolumeUsd: number;
  maxTokenAgeHours: number;
  tokenPostCooldownMinutes: number;
  maxPostsPerDay: number;
  minimumGapMinutes: number;
  maxSameContentTypeConsecutive: number;
  maxSameSourceConsecutive: number;
  manualApproval: boolean;
  dexTargetPct: number;
  gmgnTargetPct: number;
  memescopeTargetPct: number;
  textTargetPct: number;
};

export type ContentCandidate = {
  eventKey: string;
  tokenAddress: string;
  pairAddress: string | null;
  symbol: string;
  name: string;
  contentType: ContentType;
  priority: number;
  firstMarketCap: number | null;
  currentMarketCap: number | null;
  gainPct: number;
  multiple: number;
  liquidityUsd: number | null;
  volumeUsd: number | null;
  ageHours: number | null;
  callPublicId: string | null;
  milestone: string | null;
  detectedAt: string;
};

export type CaptionTemplate = {
  id: number;
  templateKey: string;
  contentType: ContentType;
  body: string;
  isActive: boolean;
  useCount: number;
};

export type QueueItem = {
  id: number;
  eventKey: string;
  tokenAddress: string;
  pairAddress: string | null;
  symbol: string;
  contentType: ContentType;
  priority: number;
  captionTemplate: string;
  caption: string;
  visualSource: VisualSource;
  screenshotPreset: ScreenshotPreset;
  imageMime: string | null;
  status: QueueStatus;
  firstMarketCap: number | null;
  currentMarketCap: number | null;
  gainPct: number;
  multiple: number;
  createdAt: string;
  scheduledAt: string | null;
  publishedAt: string | null;
  xPostId: string | null;
  telegramMessageId: number | null;
};
'@

Write-Utf8NoBom "src/lib/content-hq-types.ts" $types

# ============================================================
# CORE ENGINE
# ============================================================

$core = @'
import "server-only";

import {
  neon,
} from "@neondatabase/serverless";
import chromium from "@sparticuz/chromium";
import {
  chromium as playwrightChromium,
} from "playwright-core";
import sharp from "sharp";
import {
  TwitterApi,
} from "twitter-api-v2";

import {
  getContentHqStatus,
} from "@/lib/call-story";
import type {
  CaptionTemplate,
  ContentCandidate,
  ContentConfig,
  ContentType,
  QueueItem,
  QueueStatus,
  ScreenshotPreset,
  VisualSource,
} from "@/lib/content-hq-types";

type DbRow =
  Record<string, unknown>;

const DEFAULT_CONFIG:
  ContentConfig = {
    runnerGainPct: 100,
    bigRunnerGainPct: 300,
    moonshotGainPct: 500,
    beforeMoveGainPct: 150,
    minLiquidityUsd: 20_000,
    minVolumeUsd: 50_000,
    maxTokenAgeHours: 72,
    tokenPostCooldownMinutes: 240,
    maxPostsPerDay: 5,
    minimumGapMinutes: 40,
    maxSameContentTypeConsecutive: 1,
    maxSameSourceConsecutive: 2,
    manualApproval: true,
    dexTargetPct: 60,
    gmgnTargetPct: 20,
    memescopeTargetPct: 10,
    textTargetPct: 10,
  };

const PRIORITY:
  Record<ContentType, number> = {
    moonshot: 9,
    before_move: 8,
    big_runner: 7,
    wallet_activity: 6,
    runner: 5,
    holder_growth: 4,
    memescope_detection: 4,
    new_discovery: 3,
    weekly_recap: 3,
    text_only: 1,
  };

let schemaPromise:
  Promise<void> | null =
  null;

function sqlClient() {
  const url =
    process.env.DATABASE_URL?.trim();

  if (!url) {
    throw new Error(
      "DATABASE_URL is not configured.",
    );
  }

  return neon(url);
}

function num(
  value: unknown,
  fallback = 0,
) {
  const result =
    Number(value);

  return Number.isFinite(result)
    ? result
    : fallback;
}

function maybeNum(
  value: unknown,
) {
  if (
    value === null ||
    value === undefined ||
    value === ""
  ) {
    return null;
  }

  const result =
    Number(value);

  return Number.isFinite(result)
    ? result
    : null;
}

function str(
  value: unknown,
  fallback = "",
) {
  return typeof value === "string"
    ? value
    : fallback;
}

function escapeHtml(
  value: string,
) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function siteUrl() {
  const explicit =
    process.env
      .NEXT_PUBLIC_SITE_URL
      ?.trim();

  if (explicit) {
    return explicit.replace(
      /\/+$/,
      "",
    );
  }

  const production =
    process.env
      .VERCEL_PROJECT_PRODUCTION_URL
      ?.trim();

  if (production) {
    return `https://${production}`;
  }

  return "https://memescopes.vercel.app";
}

function compactUsd(
  value: number | null,
) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return "N/A";
  }

  if (value >= 1_000_000_000) {
    return `$${(
      value / 1_000_000_000
    ).toFixed(2)}B`;
  }

  if (value >= 1_000_000) {
    return `$${(
      value / 1_000_000
    ).toFixed(2)}M`;
  }

  if (value >= 1_000) {
    return `$${(
      value / 1_000
    ).toFixed(0)}K`;
  }

  return `$${value.toFixed(0)}`;
}

function normalizeQueue(
  row: DbRow,
): QueueItem {
  return {
    id:
      num(row.id),
    eventKey:
      str(row.event_key),
    tokenAddress:
      str(row.token_address),
    pairAddress:
      row.pair_address
        ? String(row.pair_address)
        : null,
    symbol:
      str(row.symbol),
    contentType:
      str(
        row.content_type,
      ) as ContentType,
    priority:
      num(row.priority),
    captionTemplate:
      str(
        row.caption_template,
      ),
    caption:
      str(row.caption),
    visualSource:
      str(
        row.visual_source,
      ) as VisualSource,
    screenshotPreset:
      str(
        row.screenshot_preset,
      ) as ScreenshotPreset,
    imageMime:
      row.image_mime
        ? String(row.image_mime)
        : null,
    status:
      str(
        row.status,
      ) as QueueStatus,
    firstMarketCap:
      maybeNum(
        row.first_market_cap,
      ),
    currentMarketCap:
      maybeNum(
        row.current_market_cap,
      ),
    gainPct:
      num(row.gain_pct),
    multiple:
      num(
        row.multiple,
        1,
      ),
    createdAt:
      String(row.created_at),
    scheduledAt:
      row.scheduled_at
        ? String(row.scheduled_at)
        : null,
    publishedAt:
      row.published_at
        ? String(row.published_at)
        : null,
    xPostId:
      row.x_post_id
        ? String(row.x_post_id)
        : null,
    telegramMessageId:
      maybeNum(
        row.telegram_message_id,
      ),
  };
}

export async function ensureContentHqSchema() {
  if (schemaPromise) {
    return schemaPromise;
  }

  schemaPromise = (async () => {
    const sql = sqlClient();

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_content_config (
        id INTEGER PRIMARY KEY,
        runner_gain_pct DOUBLE PRECISION NOT NULL DEFAULT 100,
        big_runner_gain_pct DOUBLE PRECISION NOT NULL DEFAULT 300,
        moonshot_gain_pct DOUBLE PRECISION NOT NULL DEFAULT 500,
        before_move_gain_pct DOUBLE PRECISION NOT NULL DEFAULT 150,
        min_liquidity_usd DOUBLE PRECISION NOT NULL DEFAULT 20000,
        min_volume_usd DOUBLE PRECISION NOT NULL DEFAULT 50000,
        max_token_age_hours DOUBLE PRECISION NOT NULL DEFAULT 72,
        token_post_cooldown_minutes INTEGER NOT NULL DEFAULT 240,
        max_posts_per_day INTEGER NOT NULL DEFAULT 5,
        minimum_gap_minutes INTEGER NOT NULL DEFAULT 40,
        max_same_content_type_consecutive INTEGER NOT NULL DEFAULT 1,
        max_same_source_consecutive INTEGER NOT NULL DEFAULT 2,
        manual_approval BOOLEAN NOT NULL DEFAULT TRUE,
        dex_target_pct INTEGER NOT NULL DEFAULT 60,
        gmgn_target_pct INTEGER NOT NULL DEFAULT 20,
        memescope_target_pct INTEGER NOT NULL DEFAULT 10,
        text_target_pct INTEGER NOT NULL DEFAULT 10,
        initialized_at TIMESTAMPTZ,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      INSERT INTO memescope_content_config (
        id
      )
      VALUES (1)
      ON CONFLICT (id)
      DO NOTHING
    `;

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_caption_templates (
        id BIGSERIAL PRIMARY KEY,
        template_key TEXT UNIQUE NOT NULL,
        content_type TEXT NOT NULL,
        body TEXT NOT NULL,
        is_active BOOLEAN NOT NULL DEFAULT TRUE,
        use_count INTEGER NOT NULL DEFAULT 0,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_content_queue (
        id BIGSERIAL PRIMARY KEY,
        event_key TEXT UNIQUE NOT NULL,
        token_address TEXT NOT NULL,
        pair_address TEXT,
        symbol TEXT NOT NULL,
        content_type TEXT NOT NULL,
        priority INTEGER NOT NULL,
        caption_template TEXT NOT NULL,
        caption TEXT NOT NULL,
        visual_source TEXT NOT NULL,
        screenshot_preset TEXT NOT NULL,
        image_base64 TEXT,
        image_mime TEXT,
        first_market_cap DOUBLE PRECISION,
        current_market_cap DOUBLE PRECISION,
        gain_pct DOUBLE PRECISION NOT NULL DEFAULT 0,
        multiple DOUBLE PRECISION NOT NULL DEFAULT 1,
        status TEXT NOT NULL DEFAULT 'draft',
        scheduled_at TIMESTAMPTZ,
        published_at TIMESTAMPTZ,
        x_post_id TEXT,
        telegram_message_id BIGINT,
        last_error TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      CREATE INDEX IF NOT EXISTS memescope_content_queue_status_idx
      ON memescope_content_queue (
        status,
        priority DESC,
        created_at ASC
      )
    `;

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_content_history (
        id BIGSERIAL PRIMARY KEY,
        token TEXT NOT NULL,
        contract_address TEXT NOT NULL,
        pair_address TEXT,
        content_type TEXT NOT NULL,
        caption_template TEXT NOT NULL,
        visual_source TEXT NOT NULL,
        screenshot_path TEXT,
        first_market_cap DOUBLE PRECISION,
        current_market_cap DOUBLE PRECISION,
        gain DOUBLE PRECISION,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        scheduled_at TIMESTAMPTZ,
        published_at TIMESTAMPTZ,
        x_post_id TEXT,
        status TEXT NOT NULL
      )
    `;

    const seeds:
      Array<
        [
          string,
          ContentType,
          string,
        ]
      > = [
        [
          "runner_01",
          "runner",
          "$TOKEN moved.\n\n$FIRST_MC -> $CURRENT_MC\n\nstill watching this one.",
        ],
        [
          "runner_02",
          "runner",
          "$TOKEN\n\nfirst spotted around $FIRST_MC.\nnow sitting near $CURRENT_MC.\n\n$MULTIPLE since detection.",
        ],
        [
          "runner_03",
          "runner",
          "interesting move on $TOKEN.\n\nfirst seen: $FIRST_MC\ncurrent: ~$CURRENT_MC",
        ],
        [
          "big_runner_01",
          "big_runner",
          "$TOKEN\n\nfirst spotted around $FIRST_MC.\nnow trading near $CURRENT_MC.\n\n$MULTIPLE.",
        ],
        [
          "big_runner_02",
          "big_runner",
          "$TOKEN kept moving.\n\n$FIRST_MC -> $CURRENT_MC\n\n$MULTIPLE since first detection.",
        ],
        [
          "moonshot_01",
          "moonshot",
          "$TOKEN\n\n$FIRST_MC -> $CURRENT_MC\n\n$MULTIPLE since first detection.",
        ],
        [
          "moonshot_02",
          "moonshot",
          "this one ran.\n\n$TOKEN\n$FIRST_MC -> $CURRENT_MC\n\n$MULTIPLE.",
        ],
        [
          "before_move_01",
          "before_move",
          "$TOKEN before the move.\n\nfirst seen around $FIRST_MC.\ncurrent: $CURRENT_MC.",
        ],
        [
          "before_move_02",
          "before_move",
          "where $TOKEN first showed up vs now.\n\n$FIRST_MC -> $CURRENT_MC",
        ],
        [
          "new_discovery_01",
          "new_discovery",
          "keeping an eye on $TOKEN.\n\nliq $LIQUIDITY | volume $VOLUME",
        ],
        [
          "new_discovery_02",
          "new_discovery",
          "$TOKEN just showed up on the scanner.\n\nwatching how it develops from here.",
        ],
        [
          "wallet_activity_01",
          "wallet_activity",
          "noticed some interesting wallet activity on $TOKEN.",
        ],
        [
          "holder_growth_01",
          "holder_growth",
          "$TOKEN\n\nholder count still climbing.",
        ],
        [
          "memescope_detection_01",
          "memescope_detection",
          "$TOKEN showed up on the scanner earlier.\n\nstill holding above the level.",
        ],
        [
          "weekly_recap_01",
          "weekly_recap",
          "this week\n\n$TOTAL_CALLS tokens tracked\n$REACHED_2X passed 2x\n$REACHED_5X passed 5x",
        ],
        [
          "text_only_01",
          "text_only",
          "small caps waking up again.\n\nwatching volume before chasing anything.",
        ],
        [
          "text_only_02",
          "text_only",
          "not much worth touching right now.\n\npatience > forcing trades.",
        ],
      ];

    for (
      const [
        key,
        contentType,
        body,
      ] of seeds
    ) {
      await sql`
        INSERT INTO memescope_caption_templates (
          template_key,
          content_type,
          body
        )
        VALUES (
          ${key},
          ${contentType},
          ${body}
        )
        ON CONFLICT (template_key)
        DO NOTHING
      `;
    }
  })();

  try {
    await schemaPromise;
  } catch (error) {
    schemaPromise = null;
    throw error;
  }
}

export async function getContentConfig():
Promise<ContentConfig & {
  initializedAt: string | null;
}> {
  await ensureContentHqSchema();

  const sql = sqlClient();

  const rows = await sql`
    SELECT *
    FROM memescope_content_config
    WHERE id = 1
    LIMIT 1
  `;

  const row =
    (rows[0] ??
      {}) as DbRow;

  return {
    runnerGainPct:
      num(
        row.runner_gain_pct,
        DEFAULT_CONFIG.runnerGainPct,
      ),
    bigRunnerGainPct:
      num(
        row.big_runner_gain_pct,
        DEFAULT_CONFIG.bigRunnerGainPct,
      ),
    moonshotGainPct:
      num(
        row.moonshot_gain_pct,
        DEFAULT_CONFIG.moonshotGainPct,
      ),
    beforeMoveGainPct:
      num(
        row.before_move_gain_pct,
        DEFAULT_CONFIG.beforeMoveGainPct,
      ),
    minLiquidityUsd:
      num(
        row.min_liquidity_usd,
        DEFAULT_CONFIG.minLiquidityUsd,
      ),
    minVolumeUsd:
      num(
        row.min_volume_usd,
        DEFAULT_CONFIG.minVolumeUsd,
      ),
    maxTokenAgeHours:
      num(
        row.max_token_age_hours,
        DEFAULT_CONFIG.maxTokenAgeHours,
      ),
    tokenPostCooldownMinutes:
      num(
        row.token_post_cooldown_minutes,
        DEFAULT_CONFIG.tokenPostCooldownMinutes,
      ),
    maxPostsPerDay:
      num(
        row.max_posts_per_day,
        DEFAULT_CONFIG.maxPostsPerDay,
      ),
    minimumGapMinutes:
      num(
        row.minimum_gap_minutes,
        DEFAULT_CONFIG.minimumGapMinutes,
      ),
    maxSameContentTypeConsecutive:
      num(
        row.max_same_content_type_consecutive,
        DEFAULT_CONFIG.maxSameContentTypeConsecutive,
      ),
    maxSameSourceConsecutive:
      num(
        row.max_same_source_consecutive,
        DEFAULT_CONFIG.maxSameSourceConsecutive,
      ),
    manualApproval:
      row.manual_approval ===
      undefined
        ? true
        : Boolean(
            row.manual_approval,
          ),
    dexTargetPct:
      num(
        row.dex_target_pct,
        60,
      ),
    gmgnTargetPct:
      num(
        row.gmgn_target_pct,
        20,
      ),
    memescopeTargetPct:
      num(
        row.memescope_target_pct,
        10,
      ),
    textTargetPct:
      num(
        row.text_target_pct,
        10,
      ),
    initializedAt:
      row.initialized_at
        ? String(
            row.initialized_at,
          )
        : null,
  };
}

export async function updateContentConfig(
  patch:
    Partial<ContentConfig>,
) {
  const current =
    await getContentConfig();

  const next = {
    ...current,
    ...patch,
  };

  const sql = sqlClient();

  await sql`
    UPDATE memescope_content_config
    SET
      runner_gain_pct = ${next.runnerGainPct},
      big_runner_gain_pct = ${next.bigRunnerGainPct},
      moonshot_gain_pct = ${next.moonshotGainPct},
      before_move_gain_pct = ${next.beforeMoveGainPct},
      min_liquidity_usd = ${next.minLiquidityUsd},
      min_volume_usd = ${next.minVolumeUsd},
      max_token_age_hours = ${next.maxTokenAgeHours},
      token_post_cooldown_minutes = ${next.tokenPostCooldownMinutes},
      max_posts_per_day = ${next.maxPostsPerDay},
      minimum_gap_minutes = ${next.minimumGapMinutes},
      max_same_content_type_consecutive = ${next.maxSameContentTypeConsecutive},
      max_same_source_consecutive = ${next.maxSameSourceConsecutive},
      manual_approval = ${next.manualApproval},
      dex_target_pct = ${next.dexTargetPct},
      gmgn_target_pct = ${next.gmgnTargetPct},
      memescope_target_pct = ${next.memescopeTargetPct},
      text_target_pct = ${next.textTargetPct},
      updated_at = NOW()
    WHERE id = 1
  `;

  return getContentConfig();
}

function contentTypeFor(
  gainPct: number,
  config: ContentConfig,
) {
  if (
    gainPct >=
    config.moonshotGainPct
  ) {
    return "moonshot" as const;
  }

  if (
    gainPct >=
    config.bigRunnerGainPct
  ) {
    return "big_runner" as const;
  }

  if (
    gainPct >=
    config.runnerGainPct
  ) {
    return "runner" as const;
  }

  return "new_discovery" as const;
}

async function discoverPairAddress(
  tokenAddress: string,
) {
  try {
    const response =
      await fetch(
        `https://api.dexscreener.com/latest/dex/tokens/${encodeURIComponent(
          tokenAddress,
        )}`,
        {
          headers: {
            Accept:
              "application/json",
          },
          cache: "no-store",
        },
      );

    if (!response.ok) {
      return null;
    }

    const body =
      (await response.json()) as {
        pairs?: Array<{
          chainId?: string;
          pairAddress?: string;
          liquidity?: {
            usd?: number;
          };
        }>;
      };

    return (
      body.pairs ?? []
    )
      .filter(
        (pair) =>
          pair.chainId ===
            "solana" &&
          pair.pairAddress,
      )
      .sort(
        (a, b) =>
          num(
            b.liquidity?.usd,
          ) -
          num(
            a.liquidity?.usd,
          ),
      )[0]
      ?.pairAddress ??
      null;
  } catch {
    return null;
  }
}

async function candidateFromCall(
  row: DbRow,
  config:
    ContentConfig,
): Promise<
  ContentCandidate | null
> {
  const tokenAddress =
    str(row.token_address);

  if (!tokenAddress) {
    return null;
  }

  const callMc =
    maybeNum(
      row.call_market_cap_usd,
    );

  const currentMc =
    maybeNum(
      row.current_market_cap_usd,
    ) ??
    maybeNum(
      row.peak_market_cap_usd,
    );

  const multiple =
    num(
      row.peak_multiple,
      1,
    );

  const gainPct =
    Math.max(
      0,
      (multiple - 1) * 100,
    );

  const liquidity =
    maybeNum(
      row.liquidity_usd,
    );

  const ageMinutes =
    maybeNum(
      row.pair_age_minutes,
    );

  if (
    liquidity !== null &&
    liquidity <
      config.minLiquidityUsd
  ) {
    return null;
  }

  if (
    ageMinutes !== null &&
    ageMinutes >
      config.maxTokenAgeHours *
        60
  ) {
    return null;
  }

  const contentType =
    contentTypeFor(
      gainPct,
      config,
    );

  const publicId =
    row.public_id
      ? String(
          row.public_id,
        )
      : null;

  const eventKey =
    `${str(
      row.signal_record_id,
      tokenAddress,
    )}:${contentType}`;

  return {
    eventKey,
    tokenAddress,
    pairAddress:
      await discoverPairAddress(
        tokenAddress,
      ),
    symbol:
      str(
        row.symbol,
        "TOKEN",
      ).replace(
        /^\$/,
        "",
      ),
    name:
      str(
        row.name,
        "Unknown Token",
      ),
    contentType,
    priority:
      PRIORITY[
        contentType
      ],
    firstMarketCap:
      callMc,
    currentMarketCap:
      currentMc,
    gainPct,
    multiple,
    liquidityUsd:
      liquidity,
    volumeUsd: null,
    ageHours:
      ageMinutes === null
        ? null
        : ageMinutes / 60,
    callPublicId:
      publicId,
    milestone:
      contentType ===
      "moonshot"
        ? `${multiple.toFixed(
            1,
          )}X`
        : contentType ===
            "big_runner"
          ? `${multiple.toFixed(
              1,
            )}X`
          : contentType ===
              "runner"
            ? `${multiple.toFixed(
                1,
              )}X`
            : null,
    detectedAt:
      String(
        row.called_at ??
          new Date().toISOString(),
      ),
  };
}

async function tokenCooldownBlocks(
  candidate:
    ContentCandidate,
  config:
    ContentConfig,
) {
  const sql = sqlClient();

  const rows = await sql`
    SELECT
      content_type,
      created_at
    FROM memescope_content_queue
    WHERE token_address = ${candidate.tokenAddress}
      AND created_at >= NOW() - (${config.tokenPostCooldownMinutes} * INTERVAL '1 minute')
    ORDER BY created_at DESC
    LIMIT 1
  `;

  if (!rows.length) {
    return false;
  }

  const previousType =
    str(
      (
        rows[0] as DbRow
      ).content_type,
    );

  const milestones =
    new Set([
      "runner",
      "big_runner",
      "moonshot",
    ]);

  if (
    milestones.has(
      candidate.contentType,
    ) &&
    previousType !==
      candidate.contentType
  ) {
    return false;
  }

  return true;
}

async function chooseSource(
  contentType:
    ContentType,
  config:
    ContentConfig,
): Promise<VisualSource> {
  if (
    contentType ===
      "wallet_activity" ||
    contentType ===
      "holder_growth"
  ) {
    return "gmgn";
  }

  if (
    contentType ===
    "text_only"
  ) {
    return "text_only";
  }

  if (
    contentType ===
    "memescope_detection"
  ) {
    return "memescope";
  }

  const sql = sqlClient();

  const rows = await sql`
    SELECT
      visual_source,
      COUNT(*)::INTEGER AS count
    FROM memescope_content_history
    WHERE created_at >= NOW() - INTERVAL '30 days'
    GROUP BY visual_source
  `;

  const counts:
    Record<VisualSource, number> = {
      dex_screener: 0,
      gmgn: 0,
      memescope: 0,
      text_only: 0,
    };

  for (const raw of rows) {
    const row =
      raw as DbRow;

    const source =
      str(
        row.visual_source,
      ) as VisualSource;

    if (
      source in counts
    ) {
      counts[source] =
        num(
          row.count,
        );
    }
  }

  const total =
    Object.values(
      counts,
    ).reduce(
      (sum, value) =>
        sum + value,
      0,
    ) || 1;

  const score = (
    source: VisualSource,
    targetPct: number,
  ) =>
    targetPct -
    (counts[source] /
      total) *
      100;

  const candidates:
    Array<
      [
        VisualSource,
        number,
      ]
    > = [
      [
        "dex_screener",
        score(
          "dex_screener",
          config.dexTargetPct,
        ),
      ],
      [
        "memescope",
        score(
          "memescope",
          config.memescopeTargetPct,
        ),
      ],
    ];

  return candidates.sort(
    (a, b) =>
      b[1] - a[1],
  )[0][0];
}

function presetFor(
  contentType:
    ContentType,
  source:
    VisualSource,
): ScreenshotPreset {
  if (
    source ===
    "text_only"
  ) {
    return "none";
  }

  if (
    source ===
    "memescope"
  ) {
    return "memescope_token";
  }

  if (
    source ===
    "gmgn"
  ) {
    if (
      contentType ===
      "holder_growth"
    ) {
      return "gmgn_holders";
    }

    if (
      contentType ===
      "wallet_activity"
    ) {
      return "gmgn_wallet";
    }

    return "gmgn_overview";
  }

  if (
    contentType ===
    "before_move"
  ) {
    return "dex_before_after";
  }

  if (
    contentType ===
      "runner" ||
    contentType ===
      "big_runner" ||
    contentType ===
      "moonshot"
  ) {
    return "dex_chart_metrics";
  }

  return "dex_chart";
}

function variables(
  candidate:
    ContentCandidate,
) {
  return {
    TOKEN:
      `$${candidate.symbol}`,
    PRICE: "N/A",
    FIRST_MC:
      compactUsd(
        candidate.firstMarketCap,
      ),
    CURRENT_MC:
      compactUsd(
        candidate.currentMarketCap,
      ),
    GAIN:
      `${candidate.gainPct.toFixed(
        0,
      )}%`,
    MULTIPLE:
      `${candidate.multiple.toFixed(
        2,
      )}x`,
    LIQUIDITY:
      compactUsd(
        candidate.liquidityUsd,
      ),
    VOLUME:
      compactUsd(
        candidate.volumeUsd,
      ),
    HOLDERS: "N/A",
    AGE:
      candidate.ageHours ===
      null
        ? "N/A"
        : `${candidate.ageHours.toFixed(
            1,
          )}h`,
    CHAIN: "Solana",
    TIME_SINCE_DETECTION:
      "N/A",
    TOTAL_CALLS: "N/A",
    REACHED_2X: "N/A",
    REACHED_5X: "N/A",
  };
}

function fillTemplate(
  body: string,
  values:
    Record<string, string>,
) {
  let result = body;

  for (
    const [
      key,
      value,
    ] of Object.entries(
      values,
    )
  ) {
    result =
      result.replaceAll(
        `$${key}`,
        value,
      );
  }

  return result;
}

async function chooseCaptionTemplate(
  contentType:
    ContentType,
): Promise<CaptionTemplate> {
  const sql = sqlClient();

  const lastRows =
    await sql`
      SELECT caption_template
      FROM memescope_content_history
      ORDER BY created_at DESC
      LIMIT 1
    `;

  const lastKey =
    lastRows.length
      ? str(
          (
            lastRows[0] as DbRow
          ).caption_template,
        )
      : "";

  const rows = await sql`
    SELECT *
    FROM memescope_caption_templates
    WHERE content_type = ${contentType}
      AND is_active = TRUE
      AND template_key <> ${lastKey}
    ORDER BY
      use_count ASC,
      id ASC
    LIMIT 1
  `;

  const fallback = await sql`
    SELECT *
    FROM memescope_caption_templates
    WHERE content_type = ${contentType}
      AND is_active = TRUE
    ORDER BY
      use_count ASC,
      id ASC
    LIMIT 1
  `;

  const row =
    (
      rows[0] ??
      fallback[0]
    ) as DbRow | undefined;

  if (!row) {
    throw new Error(
      `No caption template for ${contentType}.`,
    );
  }

  return {
    id:
      num(row.id),
    templateKey:
      str(
        row.template_key,
      ),
    contentType:
      str(
        row.content_type,
      ) as ContentType,
    body:
      str(row.body),
    isActive:
      Boolean(
        row.is_active,
      ),
    useCount:
      num(
        row.use_count,
      ),
  };
}

function sourceUrl(
  source:
    VisualSource,
  candidate:
    ContentCandidate,
) {
  if (
    source ===
    "dex_screener"
  ) {
    const locator =
      candidate.pairAddress ??
      candidate.tokenAddress;

    return `https://dexscreener.com/solana/${encodeURIComponent(
      locator,
    )}`;
  }

  if (
    source === "gmgn"
  ) {
    return `https://gmgn.ai/sol/token/${encodeURIComponent(
      candidate.tokenAddress,
    )}`;
  }

  if (
    source ===
    "memescope"
  ) {
    return `${
      siteUrl()
    }/token/${encodeURIComponent(
      candidate.tokenAddress,
    )}`;
  }

  return null;
}

async function captureRawScreenshot(
  url: string,
  source:
    VisualSource,
) {
  const executablePath =
    await chromium.executablePath();

  const browser =
    await playwrightChromium.launch(
      {
        args:
          chromium.args,
        executablePath,
        headless: true,
      },
    );

  try {
    const page =
      await browser.newPage({
        viewport: {
          width: 1600,
          height: 900,
        },
        deviceScaleFactor: 1,
      });

    await page.goto(
      url,
      {
        waitUntil:
          "domcontentloaded",
        timeout: 35_000,
      },
    );

    await page.waitForTimeout(
      source ===
      "gmgn"
        ? 7_000
        : 5_000,
    );

    await page.evaluate(() => {
      const selectors = [
        '[class*="cookie"]',
        '[id*="cookie"]',
        '[class*="modal"]',
        '[class*="popup"]',
      ];

      for (
        const selector of selectors
      ) {
        document
          .querySelectorAll(
            selector,
          )
          .forEach(
            (node) => {
              (
                node as HTMLElement
              ).style.display =
                "none";
            },
          );
      }
    }).catch(
      () => undefined,
    );

    return Buffer.from(
      await page.screenshot({
        type: "png",
        fullPage: false,
      }),
    );
  } finally {
    await browser.close();
  }
}

async function annotateScreenshot(
  image:
    Buffer,
  candidate:
    ContentCandidate,
) {
  const annotation =
    Buffer.from(
      `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
        <style>
          .label { font-family: Arial, sans-serif; font-size: 24px; fill: #f5f5f5; font-weight: 600; }
          .small { font-family: Arial, sans-serif; font-size: 18px; fill: #c7c7c7; }
        </style>
        <rect x="34" y="790" width="420" height="74" rx="10" fill="rgba(0,0,0,0.70)"/>
        <text x="58" y="825" class="small">first spotted</text>
        <text x="58" y="852" class="label">${escapeHtml(
          compactUsd(
            candidate.firstMarketCap,
          ),
        )} MC</text>

        <rect x="474" y="790" width="420" height="74" rx="10" fill="rgba(0,0,0,0.70)"/>
        <text x="498" y="825" class="small">current</text>
        <text x="498" y="852" class="label">${escapeHtml(
          compactUsd(
            candidate.currentMarketCap,
          ),
        )} MC</text>

        <text x="1450" y="858" text-anchor="end" class="small" opacity="0.68">MemeScope</text>
      </svg>`,
      "utf8",
    );

  return sharp(image)
    .composite([
      {
        input:
          annotation,
        top: 0,
        left: 0,
      },
    ])
    .webp({
      quality: 86,
    })
    .toBuffer();
}

async function screenshotForCandidate(
  candidate:
    ContentCandidate,
  source:
    VisualSource,
) {
  if (
    source ===
    "text_only"
  ) {
    return {
      buffer: null,
      mime: null,
    };
  }

  const url =
    sourceUrl(
      source,
      candidate,
    );

  if (!url) {
    return {
      buffer: null,
      mime: null,
    };
  }

  const raw =
    await captureRawScreenshot(
      url,
      source,
    );

  const annotated =
    await annotateScreenshot(
      raw,
      candidate,
    );

  return {
    buffer:
      annotated,
    mime:
      "image/webp",
  };
}

async function createQueueItem(
  candidate:
    ContentCandidate,
  config:
    ContentConfig,
) {
  const sql = sqlClient();

  const existing =
    await sql`
      SELECT id
      FROM memescope_content_queue
      WHERE event_key = ${candidate.eventKey}
      LIMIT 1
    `;

  if (existing.length) {
    return null;
  }

  if (
    await tokenCooldownBlocks(
      candidate,
      config,
    )
  ) {
    return null;
  }

  const source =
    await chooseSource(
      candidate.contentType,
      config,
    );

  const preset =
    presetFor(
      candidate.contentType,
      source,
    );

  const template =
    await chooseCaptionTemplate(
      candidate.contentType,
    );

  const caption =
    fillTemplate(
      template.body,
      variables(candidate),
    );

  const screenshot =
    await screenshotForCandidate(
      candidate,
      source,
    ).catch(
      () => ({
        buffer: null,
        mime: null,
      }),
    );

  const initialStatus:
    QueueStatus =
    config.manualApproval
      ? "queued"
      : "approved";

  const imageBase64 =
    screenshot.buffer
      ? screenshot.buffer.toString(
          "base64",
        )
      : null;

  const rows = await sql`
    INSERT INTO memescope_content_queue (
      event_key,
      token_address,
      pair_address,
      symbol,
      content_type,
      priority,
      caption_template,
      caption,
      visual_source,
      screenshot_preset,
      image_base64,
      image_mime,
      first_market_cap,
      current_market_cap,
      gain_pct,
      multiple,
      status
    )
    VALUES (
      ${candidate.eventKey},
      ${candidate.tokenAddress},
      ${candidate.pairAddress},
      ${candidate.symbol},
      ${candidate.contentType},
      ${candidate.priority},
      ${template.templateKey},
      ${caption},
      ${source},
      ${preset},
      ${imageBase64},
      ${screenshot.mime},
      ${candidate.firstMarketCap},
      ${candidate.currentMarketCap},
      ${candidate.gainPct},
      ${candidate.multiple},
      ${initialStatus}
    )
    RETURNING *
  `;

  await sql`
    UPDATE memescope_caption_templates
    SET
      use_count = use_count + 1,
      updated_at = NOW()
    WHERE id = ${template.id}
  `;

  return normalizeQueue(
    rows[0] as DbRow,
  );
}

async function telegramSendPhotoBuffer(
  chatId: string | number,
  image:
    Buffer | null,
  mime:
    string | null,
  caption:
    string,
  queueId: number,
) {
  const token =
    process.env
      .TELEGRAM_BOT_TOKEN
      ?.trim();

  if (!token) {
    return null;
  }

  const keyboard = {
    inline_keyboard: [
      [
        {
          text:
            "Approve",
          callback_data:
            `hq2:approve:${queueId}`,
        },
        {
          text:
            "Reject",
          callback_data:
            `hq2:reject:${queueId}`,
        },
      ],
      [
        {
          text:
            "New Screenshot",
          callback_data:
            `hq2:regenerate:${queueId}`,
        },
        {
          text:
            "Next Caption",
          callback_data:
            `hq2:caption:${queueId}`,
        },
      ],
      [
        {
          text:
            "Publish Now",
          callback_data:
            `hq2:publish:${queueId}`,
        },
      ],
    ],
  };

  if (!image) {
    const response =
      await fetch(
        `https://api.telegram.org/bot${token}/sendMessage`,
        {
          method: "POST",
          headers: {
            "content-type":
              "application/json",
          },
          body:
            JSON.stringify({
              chat_id:
                chatId,
              text:
                caption,
              reply_markup:
                keyboard,
            }),
        },
      );

    const body =
      (await response.json()) as {
        ok?: boolean;
        result?: {
          message_id?: number;
        };
      };

    return body.result
      ?.message_id ??
      null;
  }

  const form =
    new FormData();

  form.set(
    "chat_id",
    String(chatId),
  );

  form.set(
    "caption",
    caption.slice(
      0,
      1024,
    ),
  );

  form.set(
    "reply_markup",
    JSON.stringify(
      keyboard,
    ),
  );

  form.set(
    "photo",
    new Blob(
      [
        new Uint8Array(
          image,
        ),
      ],
      {
        type:
          mime ??
          "image/webp",
      },
    ),
    "memescope.webp",
  );

  const response =
    await fetch(
      `https://api.telegram.org/bot${token}/sendPhoto`,
      {
        method: "POST",
        body: form,
      },
    );

  const body =
    (await response.json()) as {
      ok?: boolean;
      result?: {
        message_id?: number;
      };
      description?: string;
    };

  if (!body.ok) {
    throw new Error(
      body.description ??
        "Telegram preview failed.",
    );
  }

  return body.result
    ?.message_id ??
    null;
}

async function sendQueuePreview(
  item: QueueItem,
) {
  const hq =
    await getContentHqStatus();

  if (
    !hq.configured ||
    !hq.chatId
  ) {
    return null;
  }

  const sql = sqlClient();

  const rows = await sql`
    SELECT
      image_base64,
      image_mime
    FROM memescope_content_queue
    WHERE id = ${item.id}
    LIMIT 1
  `;

  const row =
    (rows[0] ??
      {}) as DbRow;

  const image =
    row.image_base64
      ? Buffer.from(
          String(
            row.image_base64,
          ),
          "base64",
        )
      : null;

  const message =
    [
      item.caption,
      "",
      `Source: ${item.visualSource}`,
      `Content Type: ${item.contentType}`,
      `Template: ${item.captionTemplate}`,
    ].join("\n");

  const messageId =
    await telegramSendPhotoBuffer(
      hq.chatId,
      image,
      row.image_mime
        ? String(
            row.image_mime,
          )
        : null,
      message,
      item.id,
    );

  if (messageId) {
    await sql`
      UPDATE memescope_content_queue
      SET
        telegram_message_id = ${messageId},
        updated_at = NOW()
      WHERE id = ${item.id}
    `;
  }

  return messageId;
}

async function createHistory(
  item: QueueItem,
  status: string,
  xPostId:
    string | null = null,
) {
  const sql = sqlClient();

  await sql`
    INSERT INTO memescope_content_history (
      token,
      contract_address,
      pair_address,
      content_type,
      caption_template,
      visual_source,
      screenshot_path,
      first_market_cap,
      current_market_cap,
      gain,
      scheduled_at,
      published_at,
      x_post_id,
      status
    )
    VALUES (
      ${item.symbol},
      ${item.tokenAddress},
      ${item.pairAddress},
      ${item.contentType},
      ${item.captionTemplate},
      ${item.visualSource},
      ${`db://memescope_content_queue/${item.id}`},
      ${item.firstMarketCap},
      ${item.currentMarketCap},
      ${item.gainPct},
      ${item.scheduledAt},
      ${status === "published" ? new Date().toISOString() : null},
      ${xPostId},
      ${status}
    )
  `;
}

function xClient() {
  const appKey =
    process.env
      .X_API_KEY
      ?.trim();
  const appSecret =
    process.env
      .X_API_SECRET
      ?.trim();
  const accessToken =
    process.env
      .X_ACCESS_TOKEN
      ?.trim();
  const accessSecret =
    process.env
      .X_ACCESS_SECRET
      ?.trim();

  if (
    !appKey ||
    !appSecret ||
    !accessToken ||
    !accessSecret
  ) {
    return null;
  }

  return new TwitterApi({
    appKey,
    appSecret,
    accessToken,
    accessSecret,
  });
}

async function publishItem(
  item: QueueItem,
) {
  const client =
    xClient();

  if (!client) {
    throw new Error(
      "X credentials are not configured.",
    );
  }

  const sql = sqlClient();

  const rows = await sql`
    SELECT
      image_base64,
      image_mime
    FROM memescope_content_queue
    WHERE id = ${item.id}
    LIMIT 1
  `;

  const row =
    (rows[0] ??
      {}) as DbRow;

  let mediaIds:
    string[] | undefined;

  if (
    row.image_base64
  ) {
    const buffer =
      Buffer.from(
        String(
          row.image_base64,
        ),
        "base64",
      );

    const mediaId =
      await client.v1.uploadMedia(
        buffer,
        {
          mimeType:
            row.image_mime
              ? String(
                  row.image_mime,
                )
              : "image/webp",
        },
      );

    mediaIds = [
      mediaId,
    ];
  }

  const tweet =
    await client.v2.tweet({
      text:
        item.caption,
      ...(mediaIds
        ? {
            media: {
              media_ids:
                mediaIds as [
                  string,
                ],
            },
          }
        : {}),
    });

  const xPostId =
    tweet.data.id;

  await sql`
    UPDATE memescope_content_queue
    SET
      status = 'published',
      published_at = NOW(),
      x_post_id = ${xPostId},
      updated_at = NOW()
    WHERE id = ${item.id}
  `;

  await createHistory(
    item,
    "published",
    xPostId,
  );

  return xPostId;
}

function insidePublishingWindow(
  date = new Date(),
) {
  const parts =
    new Intl.DateTimeFormat(
      "en-GB",
      {
        timeZone:
          "Asia/Jakarta",
        hour:
          "2-digit",
        hourCycle:
          "h23",
      },
    ).formatToParts(
      date,
    );

  const hour =
    Number(
      parts.find(
        (part) =>
          part.type ===
          "hour",
      )?.value ??
        "0",
    );

  return (
    (hour >= 8 &&
      hour < 10) ||
    (hour >= 12 &&
      hour < 14) ||
    (hour >= 17 &&
      hour < 19) ||
    (hour >= 21 &&
      hour < 23)
  );
}

async function publishEligibleQueue(
  config:
    ContentConfig,
) {
  if (
    config.manualApproval ||
    !insidePublishingWindow()
  ) {
    return {
      published: 0,
    };
  }

  const sql = sqlClient();

  const todayRows =
    await sql`
      SELECT COUNT(*)::INTEGER AS count
      FROM memescope_content_queue
      WHERE status = 'published'
        AND published_at >= date_trunc(
          'day',
          NOW() AT TIME ZONE 'Asia/Jakarta'
        ) AT TIME ZONE 'Asia/Jakarta'
    `;

  const today =
    num(
      (
        todayRows[0] as DbRow | undefined
      )?.count,
      0,
    );

  if (
    today >=
    config.maxPostsPerDay
  ) {
    return {
      published: 0,
    };
  }

  const lastRows =
    await sql`
      SELECT
        published_at
      FROM memescope_content_queue
      WHERE status = 'published'
      ORDER BY published_at DESC
      LIMIT 1
    `;

  if (lastRows.length) {
    const last =
      new Date(
        String(
          (
            lastRows[0] as DbRow
          ).published_at,
        ),
      ).getTime();

    if (
      Date.now() -
        last <
      config.minimumGapMinutes *
        60_000
    ) {
      return {
        published: 0,
      };
    }
  }

  const rows = await sql`
    SELECT *
    FROM memescope_content_queue
    WHERE status = 'approved'
      AND (
        scheduled_at IS NULL OR
        scheduled_at <= NOW()
      )
    ORDER BY
      priority DESC,
      created_at ASC
    LIMIT 1
  `;

  if (!rows.length) {
    return {
      published: 0,
    };
  }

  const item =
    normalizeQueue(
      rows[0] as DbRow,
    );

  await publishItem(
    item,
  );

  return {
    published: 1,
    itemId: item.id,
  };
}

export async function processContentHq() {
  await ensureContentHqSchema();

  const config =
    await getContentConfig();

  const sql = sqlClient();

  if (!config.initializedAt) {
    await sql`
      UPDATE memescope_content_config
      SET
        initialized_at = NOW(),
        updated_at = NOW()
      WHERE id = 1
    `;

    return {
      initialized: true,
      created: 0,
      previewed: 0,
      published: 0,
      note:
        "Content HQ baseline created. Historical calls were not flooded.",
    };
  }

  const rows = await sql`
    SELECT *
    FROM memescope_call_story
    WHERE called_at >= ${config.initializedAt}
    ORDER BY called_at DESC
    LIMIT 200
  `;

  const candidates:
    ContentCandidate[] = [];

  for (const raw of rows) {
    const candidate =
      await candidateFromCall(
        raw as DbRow,
        config,
      );

    if (candidate) {
      candidates.push(
        candidate,
      );

      if (
        candidate.gainPct >=
          config.beforeMoveGainPct &&
        candidate.contentType !==
          "new_discovery"
      ) {
        candidates.push({
          ...candidate,
          eventKey:
            `${candidate.eventKey}:before_move`,
          contentType:
            "before_move",
          priority:
            PRIORITY.before_move,
        });
      }
    }
  }

  candidates.sort(
    (a, b) =>
      b.priority -
      a.priority,
  );

  let created = 0;
  let previewed = 0;

  for (
    const candidate of candidates
  ) {
    const item =
      await createQueueItem(
        candidate,
        config,
      );

    if (!item) {
      continue;
    }

    created += 1;

    if (
      config.manualApproval
    ) {
      const message =
        await sendQueuePreview(
          item,
        ).catch(
          () => null,
        );

      if (message) {
        previewed += 1;
      }
    }
  }

  const publish =
    await publishEligibleQueue(
      config,
    ).catch(
      () => ({
        published: 0,
      }),
    );

  return {
    initialized: false,
    created,
    previewed,
    ...publish,
  };
}

export async function listContentQueue(
  limit = 40,
) {
  await ensureContentHqSchema();

  const sql = sqlClient();

  const rows = await sql`
    SELECT *
    FROM memescope_content_queue
    ORDER BY created_at DESC
    LIMIT ${Math.min(
      Math.max(
        limit,
        1,
      ),
      100,
    )}
  `;

  return rows.map(
    (row) =>
      normalizeQueue(
        row as DbRow,
      ),
  );
}

export async function getContentStats() {
  await ensureContentHqSchema();

  const sql = sqlClient();

  const rows = await sql`
    SELECT
      COUNT(*) FILTER (
        WHERE status IN (
          'draft',
          'queued',
          'approved'
        )
      )::INTEGER AS queued,
      COUNT(*) FILTER (
        WHERE status = 'scheduled'
      )::INTEGER AS scheduled,
      COUNT(*) FILTER (
        WHERE status = 'published'
          AND published_at >= NOW() - INTERVAL '1 day'
      )::INTEGER AS published_today,
      COUNT(*) FILTER (
        WHERE status = 'failed'
      )::INTEGER AS failed
    FROM memescope_content_queue
  `;

  const row =
    (rows[0] ??
      {}) as DbRow;

  return {
    queued:
      num(
        row.queued,
      ),
    scheduled:
      num(
        row.scheduled,
      ),
    publishedToday:
      num(
        row.published_today,
      ),
    failed:
      num(
        row.failed,
      ),
  };
}

export async function getQueueMedia(
  id: number,
) {
  await ensureContentHqSchema();

  const sql = sqlClient();

  const rows = await sql`
    SELECT
      image_base64,
      image_mime
    FROM memescope_content_queue
    WHERE id = ${id}
    LIMIT 1
  `;

  const row =
    rows[0] as
      | DbRow
      | undefined;

  if (
    !row ||
    !row.image_base64
  ) {
    return null;
  }

  return {
    buffer:
      Buffer.from(
        String(
          row.image_base64,
        ),
        "base64",
      ),
    mime:
      str(
        row.image_mime,
        "image/webp",
      ),
  };
}

async function getQueueItem(
  id: number,
) {
  const sql = sqlClient();

  const rows = await sql`
    SELECT *
    FROM memescope_content_queue
    WHERE id = ${id}
    LIMIT 1
  `;

  return rows[0]
    ? normalizeQueue(
        rows[0] as DbRow,
      )
    : null;
}

async function regenerateScreenshot(
  item: QueueItem,
) {
  const config =
    await getContentConfig();

  const candidate:
    ContentCandidate = {
    eventKey:
      item.eventKey,
    tokenAddress:
      item.tokenAddress,
    pairAddress:
      item.pairAddress,
    symbol:
      item.symbol,
    name:
      item.symbol,
    contentType:
      item.contentType,
    priority:
      item.priority,
    firstMarketCap:
      item.firstMarketCap,
    currentMarketCap:
      item.currentMarketCap,
    gainPct:
      item.gainPct,
    multiple:
      item.multiple,
    liquidityUsd: null,
    volumeUsd: null,
    ageHours: null,
    callPublicId: null,
    milestone: null,
    detectedAt:
      item.createdAt,
  };

  const source =
    await chooseSource(
      item.contentType,
      config,
    );

  const screenshot =
    await screenshotForCandidate(
      candidate,
      source,
    );

  const sql = sqlClient();

  await sql`
    UPDATE memescope_content_queue
    SET
      visual_source = ${source},
      screenshot_preset = ${presetFor(
        item.contentType,
        source,
      )},
      image_base64 = ${screenshot.buffer
        ? screenshot.buffer.toString(
            "base64",
          )
        : null},
      image_mime = ${screenshot.mime},
      updated_at = NOW()
    WHERE id = ${item.id}
  `;
}

async function nextCaption(
  item: QueueItem,
) {
  const sql = sqlClient();

  const rows = await sql`
    SELECT *
    FROM memescope_caption_templates
    WHERE content_type = ${item.contentType}
      AND is_active = TRUE
      AND template_key <> ${item.captionTemplate}
    ORDER BY
      use_count ASC,
      id ASC
    LIMIT 1
  `;

  if (!rows.length) {
    return;
  }

  const row =
    rows[0] as DbRow;

  const candidate:
    ContentCandidate = {
    eventKey:
      item.eventKey,
    tokenAddress:
      item.tokenAddress,
    pairAddress:
      item.pairAddress,
    symbol:
      item.symbol,
    name:
      item.symbol,
    contentType:
      item.contentType,
    priority:
      item.priority,
    firstMarketCap:
      item.firstMarketCap,
    currentMarketCap:
      item.currentMarketCap,
    gainPct:
      item.gainPct,
    multiple:
      item.multiple,
    liquidityUsd: null,
    volumeUsd: null,
    ageHours: null,
    callPublicId: null,
    milestone: null,
    detectedAt:
      item.createdAt,
  };

  const caption =
    fillTemplate(
      str(
        row.body,
      ),
      variables(
        candidate,
      ),
    );

  await sql`
    UPDATE memescope_content_queue
    SET
      caption_template = ${str(
        row.template_key,
      )},
      caption = ${caption},
      updated_at = NOW()
    WHERE id = ${item.id}
  `;

  await sql`
    UPDATE memescope_caption_templates
    SET
      use_count = use_count + 1,
      updated_at = NOW()
    WHERE id = ${num(
      row.id,
    )}
  `;
}

export async function handleContentHqAction(
  action: string,
  id: number,
  value?: string | null,
) {
  await ensureContentHqSchema();

  const item =
    await getQueueItem(
      id,
    );

  if (!item) {
    throw new Error(
      "Content item not found.",
    );
  }

  const sql = sqlClient();

  if (action === "approve") {
    await sql`
      UPDATE memescope_content_queue
      SET
        status = 'approved',
        updated_at = NOW()
      WHERE id = ${id}
    `;

    return {
      message:
        "Approved.",
    };
  }

  if (action === "reject") {
    await sql`
      UPDATE memescope_content_queue
      SET
        status = 'rejected',
        updated_at = NOW()
      WHERE id = ${id}
    `;

    return {
      message:
        "Rejected.",
    };
  }

  if (
    action ===
    "regenerate"
  ) {
    await regenerateScreenshot(
      item,
    );

    const refreshed =
      await getQueueItem(
        id,
      );

    if (refreshed) {
      await sendQueuePreview(
        refreshed,
      ).catch(
        () => null,
      );
    }

    return {
      message:
        "New screenshot generated.",
    };
  }

  if (
    action === "caption"
  ) {
    await nextCaption(
      item,
    );

    const refreshed =
      await getQueueItem(
        id,
      );

    if (refreshed) {
      await sendQueuePreview(
        refreshed,
      ).catch(
        () => null,
      );
    }

    return {
      message:
        "Next caption template selected.",
    };
  }

  if (
    action ===
    "edit_caption"
  ) {
    const caption =
      (value ?? "")
        .trim();

    if (!caption) {
      throw new Error(
        "Caption is empty.",
      );
    }

    await sql`
      UPDATE memescope_content_queue
      SET
        caption = ${caption},
        updated_at = NOW()
      WHERE id = ${id}
    `;

    return {
      message:
        "Caption updated.",
    };
  }

  if (
    action === "schedule"
  ) {
    if (!value) {
      throw new Error(
        "Schedule time is missing.",
      );
    }

    const schedule =
      new Date(value);

    if (
      !Number.isFinite(
        schedule.getTime(),
      )
    ) {
      throw new Error(
        "Invalid schedule time.",
      );
    }

    await sql`
      UPDATE memescope_content_queue
      SET
        status = 'scheduled',
        scheduled_at = ${schedule.toISOString()},
        updated_at = NOW()
      WHERE id = ${id}
    `;

    return {
      message:
        "Scheduled.",
    };
  }

  if (
    action === "publish"
  ) {
    const xPostId =
      await publishItem(
        item,
      );

    return {
      message:
        `Published to X: ${xPostId}`,
    };
  }

  throw new Error(
    "Unknown Content HQ action.",
  );
}

export async function handleContentHqTelegramAction(
  action: string,
  id: number,
) {
  return handleContentHqAction(
    action,
    id,
  );
}

export async function listCaptionTemplates() {
  await ensureContentHqSchema();

  const sql = sqlClient();

  const rows = await sql`
    SELECT *
    FROM memescope_caption_templates
    ORDER BY
      content_type ASC,
      template_key ASC
  `;

  return rows.map(
    (raw) => {
      const row =
        raw as DbRow;

      return {
        id:
          num(
            row.id,
          ),
        templateKey:
          str(
            row.template_key,
          ),
        contentType:
          str(
            row.content_type,
          ),
        body:
          str(row.body),
        isActive:
          Boolean(
            row.is_active,
          ),
        useCount:
          num(
            row.use_count,
          ),
      };
    },
  );
}
'@

Write-Utf8NoBom "src/lib/content-hq.ts" $core

# ============================================================
# PROCESS API
# ============================================================

$processRoute = @'
import {
  NextResponse,
} from "next/server";

import {
  processContentHq,
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

  try {
    return NextResponse.json({
      ok: true,
      result:
        await processContentHq(),
    });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error:
          error instanceof Error
            ? error.message
            : "Content HQ process failed.",
      },
      {
        status: 500,
      },
    );
  }
}
'@

Write-Utf8NoBom "src/app/api/content-hq/process/route.ts" $processRoute

# ============================================================
# MEDIA API
# ============================================================

$mediaRoute = @'
import {
  getQueueMedia,
} from "@/lib/content-hq";

export const runtime =
  "nodejs";
export const dynamic =
  "force-dynamic";

export async function GET(
  _request: Request,
  context: {
    params:
      Promise<{
        id: string;
      }>;
  },
) {
  const {
    id,
  } = await context.params;

  const number =
    Number(id);

  if (
    !Number.isInteger(
      number,
    ) ||
    number <= 0
  ) {
    return new Response(
      "Invalid content id.",
      {
        status: 400,
      },
    );
  }

  const media =
    await getQueueMedia(
      number,
    );

  if (!media) {
    return new Response(
      "No media.",
      {
        status: 404,
      },
    );
  }

  return new Response(
    new Uint8Array(
      media.buffer,
    ),
    {
      headers: {
        "content-type":
          media.mime,
        "cache-control":
          "private, max-age=60",
      },
    },
  );
}
'@

Write-Utf8NoBom "src/app/api/content-hq/media/[id]/route.ts" $mediaRoute

# ============================================================
# ACTION API
# ============================================================

$actionRoute = @'
import {
  NextResponse,
} from "next/server";

import {
  handleContentHqAction,
} from "@/lib/content-hq";

function authorized(
  request: Request,
) {
  const expected =
    process.env
      .CONTENT_HQ_ADMIN_KEY
      ?.trim() ||
    process.env
      .CRON_SECRET
      ?.trim();

  return Boolean(
    expected &&
      request.headers.get(
        "x-content-hq-key",
      ) === expected,
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
    (await request.json()) as {
      action?: string;
      id?: number;
      value?: string | null;
    };

  if (
    !body.action ||
    !Number.isInteger(
      body.id,
    ) ||
    Number(
      body.id,
    ) <= 0
  ) {
    return NextResponse.json(
      {
        ok: false,
        error:
          "Invalid action request.",
      },
      {
        status: 400,
      },
    );
  }

  try {
    const result =
      await handleContentHqAction(
        body.action,
        Number(
          body.id,
        ),
        body.value,
      );

    return NextResponse.json({
      ok: true,
      ...result,
    });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error:
          error instanceof Error
            ? error.message
            : "Content action failed.",
      },
      {
        status: 500,
      },
    );
  }
}
'@

Write-Utf8NoBom "src/app/api/content-hq/action/route.ts" $actionRoute

# ============================================================
# CONFIG API
# ============================================================

$configRoute = @'
import {
  NextResponse,
} from "next/server";

import {
  getContentConfig,
  updateContentConfig,
} from "@/lib/content-hq";
import type {
  ContentConfig,
} from "@/lib/content-hq-types";

function authorized(
  request: Request,
) {
  const expected =
    process.env
      .CONTENT_HQ_ADMIN_KEY
      ?.trim() ||
    process.env
      .CRON_SECRET
      ?.trim();

  return Boolean(
    expected &&
      request.headers.get(
        "x-content-hq-key",
      ) === expected,
  );
}

export async function GET(
  request: Request,
) {
  if (!authorized(request)) {
    return NextResponse.json(
      {
        ok: false,
      },
      {
        status: 401,
      },
    );
  }

  return NextResponse.json({
    ok: true,
    config:
      await getContentConfig(),
  });
}

export async function POST(
  request: Request,
) {
  if (!authorized(request)) {
    return NextResponse.json(
      {
        ok: false,
      },
      {
        status: 401,
      },
    );
  }

  const patch =
    (await request.json()) as
      Partial<ContentConfig>;

  return NextResponse.json({
    ok: true,
    config:
      await updateContentConfig(
        patch,
      ),
  });
}
'@

Write-Utf8NoBom "src/app/api/content-hq/config/route.ts" $configRoute

# ============================================================
# DASHBOARD CLIENT
# ============================================================

$client = @'
"use client";

import {
  useState,
} from "react";

type Props = {
  id: number;
  initialCaption:
    string;
};

export function ContentActions({
  id,
  initialCaption,
}: Props) {
  const [
    caption,
    setCaption,
  ] =
    useState(
      initialCaption,
    );

  const [
    busy,
    setBusy,
  ] =
    useState(false);

  const [
    message,
    setMessage,
  ] =
    useState("");

  async function act(
    action: string,
    value?: string,
  ) {
    const key =
      window.localStorage.getItem(
        "memescope-content-hq-key",
      ) ??
      window.prompt(
        "Content HQ owner key",
      ) ??
      "";

    if (!key) {
      return;
    }

    window.localStorage.setItem(
      "memescope-content-hq-key",
      key,
    );

    setBusy(true);
    setMessage("");

    try {
      const response =
        await fetch(
          "/api/content-hq/action",
          {
            method:
              "POST",
            headers: {
              "content-type":
                "application/json",
              "x-content-hq-key":
                key,
            },
            body:
              JSON.stringify({
                action,
                id,
                value,
              }),
          },
        );

      const body =
        (await response.json()) as {
          ok?: boolean;
          message?: string;
          error?: string;
        };

      if (!response.ok) {
        throw new Error(
          body.error ??
            "Action failed.",
        );
      }

      setMessage(
        body.message ??
          "Done.",
      );

      window.setTimeout(
        () =>
          window.location.reload(),
        650,
      );
    } catch (error) {
      setMessage(
        error instanceof Error
          ? error.message
          : "Action failed.",
      );
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="mt-4 space-y-3">
      <textarea
        value={caption}
        onChange={(event) =>
          setCaption(
            event.target.value,
          )
        }
        className="min-h-28 w-full rounded-xl border border-white/10 bg-black/30 p-3 text-sm text-zinc-200 outline-none"
      />

      <div className="flex flex-wrap gap-2">
        <button
          disabled={busy}
          onClick={() =>
            void act(
              "approve",
            )
          }
          className="rounded-lg border border-emerald-400/30 px-3 py-2 text-xs text-emerald-200"
        >
          Approve
        </button>

        <button
          disabled={busy}
          onClick={() =>
            void act(
              "reject",
            )
          }
          className="rounded-lg border border-red-400/30 px-3 py-2 text-xs text-red-200"
        >
          Reject
        </button>

        <button
          disabled={busy}
          onClick={() =>
            void act(
              "regenerate",
            )
          }
          className="rounded-lg border border-white/10 px-3 py-2 text-xs text-zinc-200"
        >
          Regenerate Screenshot
        </button>

        <button
          disabled={busy}
          onClick={() =>
            void act(
              "caption",
            )
          }
          className="rounded-lg border border-white/10 px-3 py-2 text-xs text-zinc-200"
        >
          Next Caption
        </button>

        <button
          disabled={busy}
          onClick={() =>
            void act(
              "edit_caption",
              caption,
            )
          }
          className="rounded-lg border border-white/10 px-3 py-2 text-xs text-zinc-200"
        >
          Save Caption
        </button>

        <button
          disabled={busy}
          onClick={() =>
            void act(
              "publish",
            )
          }
          className="rounded-lg border border-sky-400/30 px-3 py-2 text-xs text-sky-200"
        >
          Publish Now
        </button>
      </div>

      {message ? (
        <div className="text-xs text-zinc-500">
          {message}
        </div>
      ) : null}
    </div>
  );
}
'@

Write-Utf8NoBom "src/components/content-hq-actions.tsx" $client

# ============================================================
# DASHBOARD PAGE
# ============================================================

$page = @'
import {
  ContentActions,
} from "@/components/content-hq-actions";
import {
  getContentStats,
  listContentQueue,
} from "@/lib/content-hq";

export const dynamic =
  "force-dynamic";

export default async function ContentHqPage() {
  const [
    stats,
    queue,
  ] =
    await Promise.all([
      getContentStats(),
      listContentQueue(
        36,
      ),
    ]);

  return (
    <main className="mx-auto min-h-screen w-full max-w-7xl px-4 py-7 lg:px-8">
      <div className="mb-7">
        <div className="text-xs uppercase tracking-[0.28em] text-zinc-500">
          MemeScope
        </div>
        <h1 className="mt-2 text-3xl font-semibold tracking-tight text-white">
          Content HQ
        </h1>
        <p className="mt-2 max-w-3xl text-sm leading-6 text-zinc-500">
          Deterministic content automation. Market data to rule engine to screenshot to caption template to queue. No AI content generation.
        </p>
      </div>

      <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {[
          [
            "Queued",
            stats.queued,
          ],
          [
            "Scheduled",
            stats.scheduled,
          ],
          [
            "Published Today",
            stats.publishedToday,
          ],
          [
            "Failed",
            stats.failed,
          ],
        ].map(
          ([
            label,
            value,
          ]) => (
            <div
              key={label}
              className="rounded-2xl border border-white/8 bg-white/[0.025] p-5"
            >
              <div className="text-xs uppercase tracking-[0.18em] text-zinc-600">
                {label}
              </div>
              <div className="mt-3 text-3xl font-semibold text-white">
                {value}
              </div>
            </div>
          ),
        )}
      </section>

      <section className="mt-8">
        <div className="mb-4 flex items-end justify-between gap-4">
          <div>
            <h2 className="text-xl font-medium text-white">
              Queue
            </h2>
            <p className="mt-1 text-sm text-zinc-600">
              Raw trader-style content previews.
            </p>
          </div>
        </div>

        <div className="grid gap-5 xl:grid-cols-2">
          {queue.map(
            (item) => (
              <article
                key={item.id}
                className="overflow-hidden rounded-2xl border border-white/8 bg-white/[0.02]"
              >
                {item.imageMime ? (
                  <img
                    src={`/api/content-hq/media/${item.id}`}
                    alt={`${item.symbol} content preview`}
                    className="aspect-video w-full bg-black object-cover"
                  />
                ) : (
                  <div className="flex aspect-video items-center justify-center bg-black/40 text-sm text-zinc-600">
                    Text-only post
                  </div>
                )}

                <div className="p-5">
                  <div className="flex flex-wrap items-center gap-2 text-[11px] uppercase tracking-[0.16em] text-zinc-600">
                    <span>
                      {item.visualSource}
                    </span>
                    <span>/</span>
                    <span>
                      {item.contentType}
                    </span>
                    <span>/</span>
                    <span>
                      {item.captionTemplate}
                    </span>
                    <span>/</span>
                    <span>
                      {item.status}
                    </span>
                  </div>

                  <div className="mt-3 flex items-baseline justify-between gap-4">
                    <div className="text-xl font-semibold text-white">
                      ${item.symbol}
                    </div>
                    <div className="text-sm text-zinc-500">
                      {item.multiple.toFixed(
                        2,
                      )}x
                    </div>
                  </div>

                  <ContentActions
                    id={item.id}
                    initialCaption={
                      item.caption
                    }
                  />
                </div>
              </article>
            ),
          )}
        </div>
      </section>
    </main>
  );
}
'@

Write-Utf8NoBom "src/app/content-hq/page.tsx" $page

# ============================================================
# PATCH TELEGRAM WEBHOOK
# ============================================================

$webhookPath = Join-Path $root "src\app\api\telegram\webhook\route.ts"
$webhook = [System.IO.File]::ReadAllText($webhookPath)
$webhookOriginal = $webhook

if (!$webhook.Contains('from "@/lib/content-hq"')) {
    $firstImport = $webhook.IndexOf("import ")
    if ($firstImport -lt 0) {
        throw "Telegram webhook import marker not found."
    }

    $importBlock = @'
import {
  handleContentHqTelegramAction,
} from "@/lib/content-hq";

'@

    $webhook =
      $webhook.Substring(0, $firstImport) +
      $importBlock +
      $webhook.Substring($firstImport)
}

if (!$webhook.Contains('data.startsWith("hq2:")')) {
    $callbackIdMarker = "  if (`r`n    data.startsWith("
    $existingIndex = $webhook.IndexOf('"content:"')

    if ($existingIndex -lt 0) {
        $existingIndex = $webhook.IndexOf("data.startsWith(")
    }

    if ($existingIndex -lt 0) {
        throw "Telegram callback insertion marker not found."
    }

    $insertAt = $webhook.LastIndexOf("  if (", $existingIndex)

    if ($insertAt -lt 0) {
        throw "Telegram callback block start not found."
    }

    $callbackBlock = @'
  if (
    data.startsWith(
      "hq2:",
    )
  ) {
    const [
      ,
      action,
      rawId,
    ] = data.split(":");

    const contentId =
      Number(rawId);

    if (
      !Number.isInteger(
        contentId,
      ) ||
      contentId <= 0 ||
      ![
        "approve",
        "reject",
        "regenerate",
        "caption",
        "publish",
      ].includes(action)
    ) {
      await telegramAnswerCallbackQuery(
        callbackId,
        {
          text:
            "Unknown Content HQ action.",
          showAlert: true,
        },
      );
      return;
    }

    try {
      const result =
        await handleContentHqTelegramAction(
          action,
          contentId,
        );

      await telegramAnswerCallbackQuery(
        callbackId,
        {
          text:
            result.message.slice(
              0,
              180,
            ),
        },
      );
    } catch (error) {
      await telegramAnswerCallbackQuery(
        callbackId,
        {
          text:
            error instanceof Error
              ? error.message.slice(
                  0,
                  180,
                )
              : "Content HQ action failed.",
          showAlert: true,
        },
      );
    }

    return;
  }


'@

    $webhook =
      $webhook.Substring(0, $insertAt) +
      $callbackBlock +
      $webhook.Substring($insertAt)
}

if ($webhook -ne $webhookOriginal) {
    $backupPath = Join-Path $backupDir "src\app\api\telegram\webhook\route.ts"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupPath) | Out-Null
    Copy-Item -LiteralPath $webhookPath -Destination $backupPath -Force
    [System.IO.File]::WriteAllText($webhookPath, $webhook, $utf8)
    Write-Host "Patched: src/app/api/telegram/webhook/route.ts" -ForegroundColor Green
}

# ============================================================
# CRON: recorder -> Content HQ processor
# ============================================================

$cron = @'
import {
  NextResponse,
} from "next/server";

function secretValue() {
  return (
    process.env
      .CRON_SECRET
      ?.trim() ??
    ""
  );
}

function authorized(
  request: Request,
) {
  const secret =
    secretValue();

  return Boolean(
    secret &&
      request.headers.get(
        "authorization",
      ) ===
        `Bearer ${secret}`,
  );
}

async function protectedPost(
  origin: string,
  path: string,
  secret: string,
) {
  const response =
    await fetch(
      `${origin}${path}`,
      {
        method: "POST",
        headers: {
          authorization:
            `Bearer ${secret}`,
        },
        cache: "no-store",
      },
    );

  const body =
    (await response.json()) as
      Record<string, unknown>;

  return {
    ok:
      response.ok,
    status:
      response.status,
    body,
  };
}

export async function GET(
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

  const secret =
    secretValue();

  const origin =
    new URL(
      request.url,
    ).origin;

  const recorder =
    await protectedPost(
      origin,
      "/api/signals/record",
      secret,
    );

  let contentHq:
    Record<string, unknown> =
    {};

  try {
    const content =
      await protectedPost(
        origin,
        "/api/content-hq/process",
        secret,
      );

    contentHq =
      content.body;
  } catch (error) {
    contentHq = {
      ok: false,
      error:
        error instanceof Error
          ? error.message
          : "Content HQ cycle failed.",
    };
  }

  return NextResponse.json(
    {
      ok:
        recorder.ok,
      recorder:
        recorder.body,
      contentHq,
    },
    {
      status:
        recorder.ok
          ? 200
          : recorder.status,
    },
  );
}
'@

Write-Utf8NoBom "src/app/api/telegram/cron/route.ts" $cron

# ============================================================
# BEST-EFFORT SIDEBAR LINK
# ============================================================

$appShellPath = Join-Path $root "src\components\app-shell.tsx"
if (Test-Path -LiteralPath $appShellPath) {
    $shell = [System.IO.File]::ReadAllText($appShellPath)
    $shellOriginal = $shell

    if (
      !$shell.Contains('href: "/content-hq"') -and
      $shell.Contains('href: "/calls"')
    ) {
      $pattern = '\{\s*href:\s*"/calls",\s*label:\s*"Calls"[^}]*\},'
      $match = [regex]::Match($shell, $pattern)

      if ($match.Success) {
        $insert = $match.Value + "`r`n  { href: `"/content-hq`", label: `"Content HQ`" },"
        $shell = $shell.Remove($match.Index, $match.Length).Insert($match.Index, $insert)
      }
    }

    if ($shell -ne $shellOriginal) {
      $backupPath = Join-Path $backupDir "src\components\app-shell.tsx"
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupPath) | Out-Null
      Copy-Item -LiteralPath $appShellPath -Destination $backupPath -Force
      [System.IO.File]::WriteAllText($appShellPath, $shell, $utf8)
      Write-Host "Patched: Content HQ sidebar link" -ForegroundColor Green
    }
    else {
      Write-Host "Sidebar unchanged; /content-hq is still available directly." -ForegroundColor DarkGray
    }
}

# ============================================================
# ENV EXAMPLE ONLY - NEVER TOUCH REAL SECRETS
# ============================================================

$envExamplePath = Join-Path $root ".env.example"
if (Test-Path -LiteralPath $envExamplePath) {
    $envText = [System.IO.File]::ReadAllText($envExamplePath)

    $envLines = @(
        "CONTENT_HQ_ADMIN_KEY=",
        "X_API_KEY=",
        "X_API_SECRET=",
        "X_ACCESS_TOKEN=",
        "X_ACCESS_SECRET="
    )

    foreach ($line in $envLines) {
        if (!$envText.Contains($line)) {
            $envText += "`r`n$line"
        }
    }

    [System.IO.File]::WriteAllText($envExamplePath, $envText, $utf8)
}

# ============================================================
# README
# ============================================================

$readme = @'
# MemeScope Content HQ Blueprint V2

This system follows a deterministic, zero-AI content workflow.

Flow:

Market Data
-> MemeScope Engine
-> Event Detector
-> Rule Engine
-> Content Eligibility
-> Content Type
-> Source Selector
-> Screenshot Engine
-> Annotation Engine
-> Caption Template Engine
-> Duplicate Check
-> Content Queue
-> Preview / Approval
-> Scheduler
-> X API
-> Content History

Visual policy:

- 1600x900 landscape.
- Raw trader-content look.
- DEX Screener is the default visual source.
- GMGN is available for holder / wallet content.
- MemeScope is used as a subtle first-party source.
- Text-only posts remain supported.
- No TradingView.
- No AI image generation.
- No AI caption generation.
- No AI source selection.
- No cyber-neon poster cards.
- No large marketing headlines.
- Annotation is simple and programmatic.

Default rules:

- Runner: +100%.
- Big Runner: +300%.
- Moonshot: +500%.
- Before The Move: +150%.
- Min liquidity: $20K.
- Max token age: 72h.
- Token cooldown: 4h, except a new milestone.
- Max posts/day: 5.
- Minimum gap: 40m.
- Manual approval: ON.

Content source target mix:

- DEX Screener: 60%.
- GMGN: 20%.
- MemeScope: 10%.
- Text only: 10%.

The source percentages are targets, not forced quotas.

Dashboard:

/content-hq

Dashboard mutation actions require CONTENT_HQ_ADMIN_KEY.
If CONTENT_HQ_ADMIN_KEY is absent, CRON_SECRET is accepted as the owner key.

X publishing is optional until these production variables exist:

X_API_KEY
X_API_SECRET
X_ACCESS_TOKEN
X_ACCESS_SECRET

Content HQ can run and generate Telegram previews without X credentials.
'@

Write-Utf8NoBom "README-MEMESCOPE-CONTENT-HQ-BLUEPRINT-V2.md" $readme

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " MemeScope Content HQ Blueprint V2 installed" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "IMPORTANT:" -ForegroundColor Yellow
Write-Host " - This replaces the poster-style content direction." -ForegroundColor Yellow
Write-Host " - Content generation is 100% deterministic / 0% AI." -ForegroundColor Yellow
Write-Host " - Screenshots are 1600x900 and intentionally raw/minimal." -ForegroundColor Yellow
Write-Host " - Manual approval is ON by default." -ForegroundColor Yellow
Write-Host " - X posting stays inactive until X credentials are configured." -ForegroundColor Yellow
Write-Host ""
Write-Host "Backup: $backupDir" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Run next:" -ForegroundColor Cyan
Write-Host " npm run typecheck"
Write-Host " npm run build"
