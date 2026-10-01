import "server-only";

import {
  neon,
} from "@neondatabase/serverless";

import {
  escapeTelegramHtml,
  telegramConfig,
  telegramConfigured,
  telegramSendMessage,
  telegramSendPhoto,
  telegramSiteUrl,
} from "@/lib/telegram";
import {
  compactUsd,
  getCallStoryForSignalRecord,
} from "@/lib/call-story";



type DbRow = Record<
  string,
  unknown
>;

const DEX_API = "https://api.dexscreener.com";

type SignalRecord = {
  id: string;
  signalId: string;
  tokenAddress: string;
  symbol: string;
  name: string;
  label: string;
  openedAt: number;
  closedAt: number | null;
  entryPriceUsd: number | null;
  currentPriceUsd: number | null;
  targetPercent: number;
  targetPriceUsd: number | null;
  planReason: string;
  scoreAtEntry: number;
  lastScore: number;
  status:
    | "active"
    | "target_hit"
    | "stop_loss";
  currentGainPercent: number | null;
  peakGainPercent: number | null;
  maxDrawdownPercent: number | null;
};

let schemaPromise:
  | Promise<void>
  | null = null;

function sqlClient() {
  const databaseUrl =
    process.env.DATABASE_URL?.trim();

  if (!databaseUrl) {
    throw new Error(
      "DATABASE_URL is not configured.",
    );
  }

  return neon(databaseUrl);
}

function num(
  value: unknown,
  fallback = 0,
) {
  const parsed = Number(value);

  return Number.isFinite(parsed)
    ? parsed
    : fallback;
}

function numOrNull(
  value: unknown,
) {
  if (
    value === null ||
    value === undefined
  ) {
    return null;
  }

  const parsed = Number(value);

  return Number.isFinite(parsed)
    ? parsed
    : null;
}

function millis(
  value: unknown,
) {
  if (value instanceof Date) {
    return value.getTime();
  }

  const parsed =
    Date.parse(String(value));

  return Number.isFinite(parsed)
    ? parsed
    : Date.now();
}

function nullableMillis(
  value: unknown,
) {
  if (
    value === null ||
    value === undefined
  ) {
    return null;
  }

  return millis(value);
}

function stringOrNull(
  value: unknown,
) {
  if (
    typeof value !== "string"
  ) {
    return null;
  }

  const trimmed =
    value.trim();

  return trimmed || null;
}

function objectValue(
  value: unknown,
): Record<string, unknown> | null {
  if (
    typeof value !== "object" ||
    value === null ||
    Array.isArray(value)
  ) {
    return null;
  }

  return value as Record<
    string,
    unknown
  >;
}

function objectArray(
  value: unknown,
) {
  if (!Array.isArray(value)) {
    return [] as Array<
      Record<string, unknown>
    >;
  }

  return value.filter(
    (
      item,
    ): item is Record<
      string,
      unknown
    > =>
      typeof item === "object" &&
      item !== null &&
      !Array.isArray(item),
  );
}

async function fetchPublisherJson(
  url: string,
): Promise<unknown> {
  const response =
    await fetch(url, {
      cache: "no-store",
      headers: {
        accept:
          "application/json",
      },
      signal: AbortSignal.timeout(
        8_000,
      ),
    });

  if (!response.ok) {
    throw new Error(
      "DEX request failed (" + response.status + ").",
    );
  }

  return response.json();
}

async function resolveSignalPhotoUrl(
  tokenAddress: string,
) {
  try {
    const body =
      await fetchPublisherJson(
        DEX_API + "/tokens/v1/solana/" + encodeURIComponent(
          tokenAddress,
        ),
      );

    let best: {
      rank: number;
      liquidityUsd: number;
      url: string;
    } | null = null;

    for (const pair of objectArray(
      body,
    )) {
      const baseToken =
        objectValue(
          pair.baseToken,
        );
      const address =
        stringOrNull(
          baseToken?.address,
        );

      if (
        !address ||
        address !== tokenAddress
      ) {
        continue;
      }

      const info =
        objectValue(pair.info);
      const liquidity =
        objectValue(
          pair.liquidity,
        );
      const liquidityUsd =
        numOrNull(
          liquidity?.usd,
        ) ?? 0;

      const bannerUrl =
        stringOrNull(
          info?.header,
        ) ??
        stringOrNull(
          info?.headerUrl,
        ) ??
        stringOrNull(
          pair.header,
        ) ??
        stringOrNull(
          pair.headerUrl,
        );

      const imageUrl =
        stringOrNull(
          info?.imageUrl,
        ) ??
        stringOrNull(
          info?.image,
        ) ??
        stringOrNull(
          pair.imageUrl,
        ) ??
        stringOrNull(
          pair.image,
        );

      const selectedUrl =
        bannerUrl ?? imageUrl;

      if (!selectedUrl) {
        continue;
      }

      const rank = bannerUrl
        ? 2
        : 1;

      if (
        !best ||
        rank > best.rank ||
        (rank === best.rank &&
          liquidityUsd >
            best.liquidityUsd)
      ) {
        best = {
          rank,
          liquidityUsd,
          url: selectedUrl,
        };
      }
    }

    return best?.url ?? null;
  } catch (error) {
    console.error(
      "MemeScope signal media lookup failed for " + tokenAddress + ":",
      error,
    );
    return null;
  }
}

function normalizeRecord(
  row: DbRow,
): SignalRecord {
  const rawStatus =
    String(
      row.status ?? "active",
    );

  const status:
    SignalRecord["status"] =
    rawStatus === "target_hit" ||
    rawStatus === "stop_loss"
      ? rawStatus
      : "active";

  return {
    id: String(row.id),
    signalId:
      String(row.signal_id),
    tokenAddress:
      String(row.token_address),
    symbol:
      String(row.symbol),
    name:
      String(row.name),
    label:
      String(row.label),
    openedAt:
      millis(row.opened_at),
    closedAt:
      nullableMillis(
        row.closed_at,
      ),
    entryPriceUsd:
      numOrNull(
        row.entry_price_usd,
      ),
    currentPriceUsd:
      numOrNull(
        row.current_price_usd,
      ),
    targetPercent:
      num(row.target_pct),
    targetPriceUsd:
      numOrNull(
        row.target_price_usd,
      ),
    planReason:
      String(
        row.plan_reason ?? "",
      ),
    scoreAtEntry:
      num(row.score_at_entry),
    lastScore:
      num(row.last_score),
    status,
    currentGainPercent:
      numOrNull(
        row.current_gain_pct,
      ),
    peakGainPercent:
      numOrNull(
        row.peak_gain_pct,
      ),
    maxDrawdownPercent:
      numOrNull(
        row.max_drawdown_pct,
      ),
  };
}

function money(
  value: number | null,
) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return "N/A";
  }

  if (value >= 1) {
    return `$${value.toFixed(4)}`;
  }

  return `$${value.toPrecision(6)}`;
}

function pct(
  value: number | null,
) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return "N/A";
  }

  return `${
    value > 0 ? "+" : ""
  }${value.toFixed(2)}%`;
}

function holdText(
  openedAt: number,
  closedAt: number | null,
) {
  const elapsed =
    Math.max(
      0,
      (closedAt ??
        Date.now()) -
        openedAt,
    ) / 60_000;

  if (elapsed < 60) {
    return `${Math.round(
      elapsed,
    )}m`;
  }

  const hours =
    elapsed / 60;

  if (hours < 24) {
    return `${hours.toFixed(
      1,
    )}h`;
  }

  return `${(
    hours / 24
  ).toFixed(1)}d`;
}

function signalButtons(
  record: SignalRecord,
) {
  const site =
    telegramSiteUrl();

  return {
    inline_keyboard: [
      [
        {
          text:
            "🛡 Analyze Risk",
          url:
            `${site}/token/` +
            encodeURIComponent(
              record.tokenAddress,
            ),
        },
        {
          text:
            "📊 DexScreener",
          url:
            "https://dexscreener.com/solana/" +
            encodeURIComponent(
              record.tokenAddress,
            ),
        },
      ],
      [
        {
          text:
            "🔎 Solscan",
          url:
            "https://solscan.io/token/" +
            encodeURIComponent(
              record.tokenAddress,
            ),
        },
        {
          text:
            "🌐 MemeScope",
          url: site,
        },
      ],
    ],
  };
}

function ageText(minutes: number | null) {
  if (
    minutes === null ||
    !Number.isFinite(minutes)
  ) {
    return "N/A";
  }

  if (minutes < 60) {
    return `${Math.max(
      1,
      Math.round(minutes),
    )}m`;
  }

  if (minutes < 1_440) {
    return `${(
      minutes / 60
    ).toFixed(1)}h`;
  }

  return `${(
    minutes / 1_440
  ).toFixed(1)}d`;
}

function setupLabel(
  score: number,
  pairAgeMinutes: number | null,
) {
  if (score >= 88) {
    return "🟢 <b>HIGH QUALITY SETUP</b>";
  }

  if (score >= 80) {
    return "🔥 <b>HIGH CONVICTION</b>";
  }

  if (
    pairAgeMinutes !== null &&
    pairAgeMinutes <= 180
  ) {
    return "⚡ <b>EARLY MOMENTUM</b>";
  }

  return "🚨 <b>MOMENTUM SETUP</b>";
}

async function channelText(
  record: SignalRecord,
) {
  const story =
    await getCallStoryForSignalRecord(
      record.id,
    );

  const publicId =
    story?.publicId ||
    record.signalId;

  const transactions =
    story?.transactions5m ??
    null;

  const liquidityRatioPct =
    story?.liquidityUsd !== null &&
    story?.liquidityUsd !== undefined &&
    story?.callMarketCapUsd !== null &&
    story?.callMarketCapUsd !== undefined &&
    story.callMarketCapUsd > 0
      ? (
          story.liquidityUsd /
          story.callMarketCapUsd
        ) * 100
      : null;

  const why = [
    story?.buyPressurePct === null ||
    story?.buyPressurePct === undefined
      ? null
      : transactions === null
        ? `• Buy pressure reached <b>${story.buyPressurePct.toFixed(
            0,
          )}%</b>`
        : `• Buy pressure reached <b>${story.buyPressurePct.toFixed(
            0,
          )}%</b> across <b>${Math.round(
            transactions,
          )}</b> transactions`,
    story?.volumeSpike === null ||
    story?.volumeSpike === undefined
      ? null
      : `• 5m volume expanded to <b>${story.volumeSpike.toFixed(
          2,
        )}x</b> the recent baseline`,
    story?.liquidityUsd === null ||
    story?.liquidityUsd === undefined
      ? null
      : `• Liquidity remains at <b>${compactUsd(
          story.liquidityUsd,
        )}</b>`,
    liquidityRatioPct === null
      ? null
      : `• Liquidity / valuation stands at <b>${liquidityRatioPct.toFixed(
          1,
        )}%</b>`,
    story?.priceChange5m === null ||
    story?.priceChange5m === undefined
      ? null
      : `• Short-term momentum is <b>${pct(
          story.priceChange5m,
        )}</b> over 5m`,
  ].filter(
    (value): value is string =>
      value !== null,
  );

  return [
    "⚡ <b>MEMESCOPE SIGNAL</b>",
    "",
    setupLabel(
      record.scoreAtEntry,
      story?.pairAgeMinutes ??
        null,
    ),
    "",
    `<b>$${escapeTelegramHtml(
      record.symbol,
    )}</b> | ${escapeTelegramHtml(
      record.name,
    )}`,
    `<code>${escapeTelegramHtml(
      publicId,
    )}</code>`,
    "",
    "╭─ <b>MARKET SNAPSHOT</b>",
    `├ 💰 Market Cap <b>${compactUsd(
      story?.callMarketCapUsd ??
        null,
    )}</b>`,
    `├ 💧 Liquidity <b>${compactUsd(
      story?.liquidityUsd ??
        null,
    )}</b>`,
    `├ 📊 Volume 5m <b>${compactUsd(
      story?.volume5mUsd ??
        null,
    )}</b>`,
    `├ 🔥 Volume Expansion <b>${
      story?.volumeSpike === null ||
      story?.volumeSpike === undefined
        ? "N/A"
        : `${story.volumeSpike.toFixed(
            2,
          )}x`
    }</b>`,
    `├ 🟢 Buy Pressure <b>${
      story?.buyPressurePct === null ||
      story?.buyPressurePct === undefined
        ? "N/A"
        : `${story.buyPressurePct.toFixed(
            0,
          )}%`
    }</b>`,
    `├ 📈 5m Momentum <b>${pct(
      story?.priceChange5m ??
        null,
    )}</b>`,
    `├ 🔄 Transactions <b>${
      transactions === null
        ? "N/A"
        : Math.round(
            transactions,
          ).toLocaleString(
            "en-US",
          )
    }</b>`,
    `╰ ⏱ Age <b>${ageText(
      story?.pairAgeMinutes ??
        null,
    )}</b>`,
    "",
    "╭─ <b>SIGNAL</b>",
    `├ 🎯 Quality Score <b>${Math.round(
      record.scoreAtEntry,
    )} / 100</b>`,
    `├ 💵 Entry <b>${money(
      record.entryPriceUsd,
    )}</b>`,
    "╰ 🟢 Status <b>LIVE</b>",
    "",
    "📌 <b>Why MemeScope detected it</b>",
    ...(why.length > 0
      ? why
      : [
          "• Setup passed the active MemeScope signal filters",
        ]),
    "",
    "📋 <b>Contract</b>",
    `<code>${escapeTelegramHtml(
      record.tokenAddress,
    )}</code>`,
    "",
    "⚡ <i>MemeScope continues live tracking after publication.</i>",
    "",
    "<b>MemeScope</b>",
  ].join("\n");
}

export async function ensureTelegramPublisherSchema() {
  if (schemaPromise) {
    return schemaPromise;
  }

  schemaPromise =
    (async () => {
      const sql =
        sqlClient();

      await sql`
        CREATE TABLE IF NOT EXISTS memescope_telegram_state (
          id INTEGER PRIMARY KEY,
          initialized_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
      `;

      await sql`
        CREATE TABLE IF NOT EXISTS memescope_telegram_posts (
          signal_record_id TEXT PRIMARY KEY,
          signal_id TEXT NOT NULL,
          channel_id TEXT NOT NULL,
          message_id BIGINT,
          baseline BOOLEAN NOT NULL DEFAULT FALSE,
          first_sent_at TIMESTAMPTZ,
          last_edited_at TIMESTAMPTZ,
          target_notified_at TIMESTAMPTZ,
          last_status TEXT NOT NULL DEFAULT 'active',
          last_current_gain_pct DOUBLE PRECISION,
          last_peak_gain_pct DOUBLE PRECISION,
          last_drawdown_pct DOUBLE PRECISION,
          created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
      `;

      await sql`
        CREATE INDEX IF NOT EXISTS memescope_telegram_signal_idx
        ON memescope_telegram_posts (signal_id)
      `;
    })().catch(
      (error) => {
        schemaPromise = null;
        throw error;
      },
    );

  return schemaPromise;
}

export async function initializeTelegramBaseline() {
  await ensureTelegramPublisherSchema();

  const sql =
    sqlClient();

  const current =
    await sql`
      SELECT initialized_at
      FROM memescope_telegram_state
      WHERE id = 1
      LIMIT 1
    `;

  if (current[0]) {
    return {
      initialized: false,
      baselineCount: 0,
      initializedAt:
        millis(
          (
            current[0] as DbRow
          ).initialized_at,
        ),
    };
  }

  const now =
    new Date();

  await sql`
    INSERT INTO memescope_telegram_state (
      id,
      initialized_at
    )
    VALUES (
      1,
      ${now.toISOString()}
    )
    ON CONFLICT (id)
    DO NOTHING
  `;

  const { channelId } =
    telegramConfig();

  const baselineRows =
    await sql`
      SELECT id, signal_id, status
      FROM memescope_signal_records
      WHERE opened_at <= ${now.toISOString()}
    `;

  for (
    const raw of baselineRows
  ) {
    const row =
      raw as DbRow;

    await sql`
      INSERT INTO memescope_telegram_posts (
        signal_record_id,
        signal_id,
        channel_id,
        baseline,
        last_status
      )
      VALUES (
        ${String(row.id)},
        ${String(
          row.signal_id,
        )},
        ${channelId},
        TRUE,
        ${String(
          row.status ??
            "active",
        )}
      )
      ON CONFLICT (
        signal_record_id
      )
      DO NOTHING
    `;
  }

  return {
    initialized: true,
    baselineCount:
      baselineRows.length,
    initializedAt:
      now.getTime(),
  };
}

export async function publishPendingTelegramSignals(
  recordIds: string[] = [],
) {
  if (!telegramConfigured()) {
    return {
      configured: false,
      initialized: false,
      directRecordCount: recordIds.length,
      attempted: 0,
      sent: 0,
      failed: 0,
      mediaFallbacks: 0,
      lastError: null,
      edited: 0,
      targetReplies: 0,
    };
  }

  await ensureTelegramPublisherSchema();

  const sql = sqlClient();
  const { channelId } = telegramConfig();

  let initialized = false;
  let baselineCount = 0;
  let rows: DbRow[] = [];

  // Fresh records opened by THIS recorder invocation bypass the historical
  // baseline selector. This makes opening + Telegram delivery one atomic
  // application flow while the DB post table still prevents repeat sends.
  const directIds = Array.from(
    new Set(
      recordIds
        .map((value) => value.trim())
        .filter(Boolean),
    ),
  ).slice(0, 25);

  if (directIds.length > 0) {
    for (const recordId of directIds) {
      const found = await sql\`
        SELECT
          r.*,
          p.message_id AS telegram_message_id
        FROM memescope_signal_records r
        LEFT JOIN memescope_telegram_posts p
          ON p.signal_record_id = r.id
        WHERE r.id = \${recordId}
        LIMIT 1
      \`;

      if (found[0]) {
        rows.push(found[0] as DbRow);
      }
    }
  } else {
    const baseline = await initializeTelegramBaseline();
    initialized = baseline.initialized;
    baselineCount = baseline.baselineCount ?? 0;

    if (baseline.initialized) {
      return {
        configured: true,
        initialized: true,
        baselineCount,
        directRecordCount: 0,
        attempted: 0,
        sent: 0,
        failed: 0,
        mediaFallbacks: 0,
        lastError: null,
        edited: 0,
        targetReplies: 0,
      };
    }

    rows = (await sql\`
      SELECT
        r.*,
        p.message_id AS telegram_message_id
      FROM memescope_signal_records r
      LEFT JOIN memescope_telegram_posts p
        ON p.signal_record_id = r.id
      WHERE (
        r.opened_at > \${new Date(
          baseline.initializedAt,
        ).toISOString()}
        OR (
          r.opened_at >= NOW() - INTERVAL '30 minutes'
          AND p.message_id IS NULL
        )
      )
      ORDER BY r.opened_at ASC
      LIMIT 150
    \`) as DbRow[];
  }

  let attempted = 0;
  let sent = 0;
  let failed = 0;
  let mediaFallbacks = 0;
  let lastError: string | null = null;

  for (const raw of rows) {
    const record = normalizeRecord(raw);
    const messageId = numOrNull(raw.telegram_message_id);

    if (messageId !== null) {
      await sql\`
        UPDATE memescope_telegram_posts
        SET
          last_status = \${record.status},
          last_current_gain_pct = \${record.currentGainPercent},
          last_peak_gain_pct = \${record.peakGainPercent},
          last_drawdown_pct = \${record.maxDrawdownPercent}
        WHERE signal_record_id = \${record.id}
      \`;
      continue;
    }

    attempted += 1;

    try {
      const text = await channelText(record);
      const photoUrl = await resolveSignalPhotoUrl(record.tokenAddress);

      let message;

      if (photoUrl) {
        try {
          message = await telegramSendPhoto(
            channelId,
            photoUrl,
            {
              caption: text,
              replyMarkup: signalButtons(record),
            },
          );
        } catch (mediaError) {
          mediaFallbacks += 1;
          console.error(
            'MemeScope VIP media send failed; falling back to text for ' +
              record.tokenAddress +
              ':',
            mediaError,
          );

          message = await telegramSendMessage(
            channelId,
            text,
            {
              replyMarkup: signalButtons(record),
            },
          );
        }
      } else {
        message = await telegramSendMessage(
          channelId,
          text,
          {
            replyMarkup: signalButtons(record),
          },
        );
      }

      await sql\`
        INSERT INTO memescope_telegram_posts (
          signal_record_id,
          signal_id,
          channel_id,
          message_id,
          baseline,
          first_sent_at,
          last_edited_at,
          last_status,
          last_current_gain_pct,
          last_peak_gain_pct,
          last_drawdown_pct
        )
        VALUES (
          \${record.id},
          \${record.signalId},
          \${channelId},
          \${message.message_id},
          FALSE,
          NOW(),
          NULL,
          \${record.status},
          \${record.currentGainPercent},
          \${record.peakGainPercent},
          \${record.maxDrawdownPercent}
        )
        ON CONFLICT (signal_record_id)
        DO UPDATE SET
          message_id = COALESCE(
            memescope_telegram_posts.message_id,
            EXCLUDED.message_id
          ),
          channel_id = EXCLUDED.channel_id,
          baseline = FALSE,
          first_sent_at = COALESCE(
            memescope_telegram_posts.first_sent_at,
            NOW()
          ),
          last_status = EXCLUDED.last_status,
          last_current_gain_pct = EXCLUDED.last_current_gain_pct,
          last_peak_gain_pct = EXCLUDED.last_peak_gain_pct,
          last_drawdown_pct = EXCLUDED.last_drawdown_pct
      \`;

      sent += 1;
    } catch (error) {
      failed += 1;
      lastError =
        error instanceof Error
          ? error.message
          : 'Unknown Telegram publisher error.';

      console.error(
        'MemeScope VIP signal publish failed for ' +
          record.tokenAddress +
          ':',
        error,
      );
    }
  }

  return {
    configured: true,
    initialized,
    baselineCount,
    directRecordCount: directIds.length,
    attempted,
    sent,
    failed,
    mediaFallbacks,
    lastError,
    edited: 0,
    targetReplies: 0,
  };
}
