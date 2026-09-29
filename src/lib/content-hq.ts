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
        ? new Date(
            String(
              row.initialized_at,
            ),
          ).toISOString()
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

type RawScreenshotResult = {
  buffer: Buffer;
  challengeDetected: boolean;
};

type DexMarketSnapshot = {
  pairAddress: string | null;
  dexId: string | null;
  quoteSymbol: string | null;
  priceUsd: number | null;
  marketCapUsd: number | null;
  liquidityUsd: number | null;
  volume24hUsd: number | null;
  buys5m: number | null;
  sells5m: number | null;
  change5mPct: number | null;
  change1hPct: number | null;
};

type CandlePoint = {
  timestamp: number;
  close: number;
};

async function captureRawScreenshot(
  url: string,
  source:
    VisualSource,
): Promise<RawScreenshotResult> {
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

    const challengeDetected =
      await page
        .evaluate(() => {
          const body =
            (
              document.body
                ?.innerText ??
              ""
            ).toLowerCase();

          const title =
            document.title
              .toLowerCase();

          const securityText =
            body.includes(
              "performing security verification",
            ) ||
            body.includes(
              "verify you are human",
            ) ||
            body.includes(
              "checking your browser",
            ) ||
            title.includes(
              "just a moment",
            );

          const securityUi =
            Boolean(
              document.querySelector(
                [
                  'iframe[src*="challenges.cloudflare.com"]',
                  '[name="cf-turnstile-response"]',
                  "#challenge-stage",
                ].join(","),
              ),
            );

          return (
            securityText ||
            securityUi
          );
        })
        .catch(
          () => false,
        );

    if (!challengeDetected) {
      await page
        .evaluate(() => {
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
        })
        .catch(
          () => undefined,
        );
    }

    return {
      buffer:
        Buffer.from(
          await page.screenshot({
            type: "png",
            fullPage: false,
          }),
        ),
      challengeDetected,
    };
  } finally {
    await browser.close();
  }
}

async function fetchDexMarketSnapshot(
  candidate:
    ContentCandidate,
): Promise<DexMarketSnapshot> {
  const response =
    await fetch(
      `https://api.dexscreener.com/latest/dex/tokens/${encodeURIComponent(
        candidate.tokenAddress,
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
    throw new Error(
      `DEX Screener API returned ${response.status}.`,
    );
  }

  const body =
    (await response.json()) as {
      pairs?: Array<{
        chainId?: string;
        pairAddress?: string;
        dexId?: string;
        quoteToken?: {
          symbol?: string;
        };
        priceUsd?: string;
        marketCap?: number;
        fdv?: number;
        liquidity?: {
          usd?: number;
        };
        volume?: {
          h24?: number;
        };
        txns?: {
          m5?: {
            buys?: number;
            sells?: number;
          };
        };
        priceChange?: {
          m5?: number;
          h1?: number;
        };
      }>;
    };

  const pairs =
    (
      body.pairs ?? []
    ).filter(
      (pair) =>
        pair.chainId ===
        "solana",
    );

  const selected =
    pairs.find(
      (pair) =>
        candidate.pairAddress &&
        pair.pairAddress ===
          candidate.pairAddress,
    ) ??
    pairs.sort(
      (a, b) =>
        num(
          b.liquidity?.usd,
        ) -
        num(
          a.liquidity?.usd,
        ),
    )[0];

  if (!selected) {
    return {
      pairAddress:
        candidate.pairAddress,
      dexId: null,
      quoteSymbol: null,
      priceUsd: null,
      marketCapUsd:
        candidate.currentMarketCap,
      liquidityUsd:
        candidate.liquidityUsd,
      volume24hUsd:
        candidate.volumeUsd,
      buys5m: null,
      sells5m: null,
      change5mPct: null,
      change1hPct: null,
    };
  }

  return {
    pairAddress:
      selected.pairAddress ??
      candidate.pairAddress,
    dexId:
      selected.dexId ??
      null,
    quoteSymbol:
      selected.quoteToken
        ?.symbol ??
      null,
    priceUsd:
      selected.priceUsd
        ? num(
            selected.priceUsd,
            NaN,
          )
        : null,
    marketCapUsd:
      maybeNum(
        selected.marketCap ??
          selected.fdv,
      ),
    liquidityUsd:
      maybeNum(
        selected.liquidity
          ?.usd,
      ),
    volume24hUsd:
      maybeNum(
        selected.volume
          ?.h24,
      ),
    buys5m:
      maybeNum(
        selected.txns
          ?.m5
          ?.buys,
      ),
    sells5m:
      maybeNum(
        selected.txns
          ?.m5
          ?.sells,
      ),
    change5mPct:
      maybeNum(
        selected.priceChange
          ?.m5,
      ),
    change1hPct:
      maybeNum(
        selected.priceChange
          ?.h1,
      ),
  };
}

async function fetchGeckoCandles(
  pairAddress:
    string | null,
): Promise<CandlePoint[]> {
  if (!pairAddress) {
    return [];
  }

  const url =
    `https://api.geckoterminal.com/api/v2/networks/solana/pools/${encodeURIComponent(
      pairAddress,
    )}/ohlcv/minute?aggregate=5&limit=100&currency=usd&token=base`;

  try {
    const response =
      await fetch(
        url,
        {
          headers: {
            Accept:
              "application/json;version=20230203",
          },
          cache: "no-store",
        },
      );

    if (!response.ok) {
      return [];
    }

    const body =
      (await response.json()) as {
        data?: {
          attributes?: {
            ohlcv_list?:
              Array<
                Array<number>
              >;
          };
        };
      };

    return (
      body.data
        ?.attributes
        ?.ohlcv_list ??
      []
    )
      .map(
        (row) => ({
          timestamp:
            num(
              row[0],
            ) * 1000,
          close:
            num(
              row[4],
              NaN,
            ),
        }),
      )
      .filter(
        (point) =>
          Number.isFinite(
            point.timestamp,
          ) &&
          Number.isFinite(
            point.close,
          ) &&
          point.close > 0,
      )
      .sort(
        (a, b) =>
          a.timestamp -
          b.timestamp,
      );
  } catch {
    return [];
  }
}

function xmlText(
  value: string,
) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function formatPrice(
  value: number | null,
) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return "N/A";
  }

  if (value >= 1) {
    return `$${value.toFixed(
      4,
    )}`;
  }

  if (value >= 0.01) {
    return `$${value.toFixed(
      6,
    )}`;
  }

  return `$${value.toPrecision(
    5,
  )}`;
}

function buildChartGeometry(
  candles:
    CandlePoint[],
  detectedAt:
    string,
) {
  const left = 90;
  const top = 178;
  const width = 1040;
  const height = 490;

  if (
    candles.length < 2
  ) {
    return {
      polyline: "",
      firstX: null as
        | number
        | null,
      firstY: null as
        | number
        | null,
      currentX: null as
        | number
        | null,
      currentY: null as
        | number
        | null,
    };
  }

  const values =
    candles.map(
      (point) =>
        point.close,
    );

  const min =
    Math.min(
      ...values,
    );

  const max =
    Math.max(
      ...values,
    );

  const range =
    Math.max(
      max - min,
      max * 0.015,
      1e-12,
    );

  const points =
    candles.map(
      (
        point,
        index,
      ) => {
        const x =
          left +
          (index /
            (candles.length -
              1)) *
            width;

        const y =
          top +
          height -
          ((point.close -
            min) /
            range) *
            height;

        return {
          x,
          y,
          timestamp:
            point.timestamp,
        };
      },
    );

  const detectedMs =
    new Date(
      detectedAt,
    ).getTime();

  let first:
    {
      x: number;
      y: number;
      timestamp: number;
    } | null =
    null;

  if (
    Number.isFinite(
      detectedMs,
    ) &&
    detectedMs >=
      candles[0].timestamp &&
    detectedMs <=
      candles[
        candles.length - 1
      ].timestamp
  ) {
    first =
      points.reduce(
        (
          best,
          point,
        ) =>
          Math.abs(
            point.timestamp -
              detectedMs,
          ) <
          Math.abs(
            best.timestamp -
              detectedMs,
          )
            ? point
            : best,
        points[0],
      );
  }

  const current =
    points[
      points.length - 1
    ];

  return {
    polyline:
      points
        .map(
          (point) =>
            `${point.x.toFixed(
              1,
            )},${point.y.toFixed(
              1,
            )}`,
        )
        .join(" "),
    firstX:
      first?.x ??
      null,
    firstY:
      first?.y ??
      null,
    currentX:
      current.x,
    currentY:
      current.y,
  };
}

async function renderDexFallback(
  candidate:
    ContentCandidate,
) {
  const market =
    await fetchDexMarketSnapshot(
      candidate,
    );

  const candles =
    await fetchGeckoCandles(
      market.pairAddress,
    );

  const chart =
    buildChartGeometry(
      candles,
      candidate.detectedAt,
    );

  const currentMc =
    market.marketCapUsd ??
    candidate.currentMarketCap;

  const liquidity =
    market.liquidityUsd ??
    candidate.liquidityUsd;

  const volume =
    market.volume24hUsd ??
    candidate.volumeUsd;

  const buySell =
    market.buys5m ===
      null &&
    market.sells5m === null
      ? "N/A"
      : `${market.buys5m ?? 0} / ${market.sells5m ?? 0}`;

  const chartBody =
    chart.polyline
      ? `<polyline points="${chart.polyline}" fill="none" stroke="#e6e6e6" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>
         <polyline points="${chart.polyline} 1130,668 90,668" fill="rgba(255,255,255,0.025)" stroke="none"/>`
      : `<text x="610" y="430" text-anchor="middle" class="muted">chart data temporarily unavailable</text>`;

  const firstMarker =
    chart.firstX !== null &&
    chart.firstY !== null
      ? `<circle cx="${chart.firstX}" cy="${chart.firstY}" r="7" fill="#ffffff"/>
         <line x1="${chart.firstX}" y1="${chart.firstY - 4}" x2="${chart.firstX}" y2="${chart.firstY - 58}" stroke="#ffffff" stroke-width="2"/>
         <text x="${chart.firstX}" y="${chart.firstY - 70}" text-anchor="middle" class="small">first spotted</text>`
      : "";

  const currentMarker =
    chart.currentX !== null &&
    chart.currentY !== null
      ? `<circle cx="${chart.currentX}" cy="${chart.currentY}" r="7" fill="#73e0aa"/>
         <line x1="${chart.currentX}" y1="${chart.currentY - 4}" x2="${chart.currentX}" y2="${chart.currentY - 58}" stroke="#73e0aa" stroke-width="2"/>
         <text x="${chart.currentX}" y="${chart.currentY - 70}" text-anchor="middle" class="small green">current</text>`
      : "";

  const svg =
    `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect width="1600" height="900" fill="#0b0b0b"/>
      <style>
        .title { font-family: Arial, sans-serif; font-size: 36px; fill: #f3f3f3; font-weight: 700; }
        .sub { font-family: Arial, sans-serif; font-size: 18px; fill: #8e8e8e; }
        .label { font-family: Arial, sans-serif; font-size: 17px; fill: #777777; }
        .value { font-family: Arial, sans-serif; font-size: 30px; fill: #eeeeee; font-weight: 600; }
        .small { font-family: Arial, sans-serif; font-size: 17px; fill: #dddddd; }
        .green { fill: #73e0aa; }
        .muted { font-family: Arial, sans-serif; font-size: 22px; fill: #666666; }
      </style>

      <text x="72" y="68" class="title">$${xmlText(
        candidate.symbol,
      )} / ${xmlText(
        market.quoteSymbol ?? "SOL",
      )}</text>
      <text x="72" y="101" class="sub">${xmlText(
        market.dexId ?? "Solana DEX",
      )} | 5m</text>
      <text x="1528" y="70" text-anchor="end" class="sub">MemeScope</text>

      <line x1="72" y1="128" x2="1528" y2="128" stroke="#252525"/>

      <rect x="72" y="150" width="1080" height="548" rx="10" fill="#0d0d0d" stroke="#242424"/>
      <line x1="90" y1="668" x2="1130" y2="668" stroke="#242424"/>
      <line x1="90" y1="545" x2="1130" y2="545" stroke="#171717"/>
      <line x1="90" y1="422" x2="1130" y2="422" stroke="#171717"/>
      <line x1="90" y1="299" x2="1130" y2="299" stroke="#171717"/>

      ${chartBody}
      ${firstMarker}
      ${currentMarker}

      <rect x="1182" y="150" width="346" height="548" rx="10" fill="#0d0d0d" stroke="#242424"/>

      <text x="1215" y="201" class="label">price</text>
      <text x="1215" y="239" class="value">${xmlText(
        formatPrice(
          market.priceUsd,
        ),
      )}</text>

      <text x="1215" y="302" class="label">market cap</text>
      <text x="1215" y="340" class="value">${xmlText(
        compactUsd(
          currentMc,
        ),
      )}</text>

      <text x="1215" y="403" class="label">liquidity</text>
      <text x="1215" y="441" class="value">${xmlText(
        compactUsd(
          liquidity,
        ),
      )}</text>

      <text x="1215" y="504" class="label">24h volume</text>
      <text x="1215" y="542" class="value">${xmlText(
        compactUsd(
          volume,
        ),
      )}</text>

      <text x="1215" y="605" class="label">5m buys / sells</text>
      <text x="1215" y="643" class="value">${xmlText(
        buySell,
      )}</text>

      <rect x="72" y="728" width="456" height="105" rx="10" fill="#101010" stroke="#242424"/>
      <text x="100" y="766" class="label">first spotted</text>
      <text x="100" y="807" class="value">${xmlText(
        compactUsd(
          candidate.firstMarketCap,
        ),
      )} MC</text>

      <rect x="548" y="728" width="456" height="105" rx="10" fill="#101010" stroke="#242424"/>
      <text x="576" y="766" class="label">current</text>
      <text x="576" y="807" class="value">${xmlText(
        compactUsd(
          currentMc,
        ),
      )} MC</text>

      <rect x="1024" y="728" width="504" height="105" rx="10" fill="#101010" stroke="#242424"/>
      <text x="1052" y="766" class="label">since first detection</text>
      <text x="1052" y="807" class="value">${xmlText(
        `${candidate.multiple.toFixed(
          2,
        )}x`,
      )}</text>

      <text x="72" y="874" class="sub">Market data: DEX Screener | Chart data: ${candles.length ? "GeckoTerminal" : "unavailable"} | Render: MemeScope</text>
    </svg>`;

  return sharp(
    Buffer.from(
      svg,
      "utf8",
    ),
  )
    .webp({
      quality: 90,
    })
    .toBuffer();
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

  if (
    source ===
    "dex_screener"
  ) {
    try {
      const raw =
        await captureRawScreenshot(
          url,
          source,
        );

      if (
        !raw.challengeDetected
      ) {
        const annotated =
          await annotateScreenshot(
            raw.buffer,
            candidate,
          );

        return {
          buffer:
            annotated,
          mime:
            "image/webp",
        };
      }
    } catch {
      // Browser capture failed. Use the deterministic fallback below.
    }

    const fallback =
      await renderDexFallback(
        candidate,
      );

    return {
      buffer:
        fallback,
      mime:
        "image/webp",
    };
  }

  const raw =
    await captureRawScreenshot(
      url,
      source,
    );

  if (
    raw.challengeDetected
  ) {
    return {
      buffer: null,
      mime: null,
    };
  }

  const annotated =
    await annotateScreenshot(
      raw.buffer,
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
  forcedSource?:
    VisualSource,
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
    forcedSource ??
    (await chooseSource(
      candidate.contentType,
      config,
    ));

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