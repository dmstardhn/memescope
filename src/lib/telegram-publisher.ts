import "server-only";

import {
  neon,
} from "@neondatabase/serverless";

import {
  escapeTelegramHtml,
  telegramConfig,
  telegramConfigured,
  telegramSendMessage,
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

type TelegramMarketSnapshot = {
  marketCapUsd: number | null;
  liquidityUsd: number | null;
  volume5mUsd: number | null;
  buyPressure: number | null;
  volumeSpike: number | null;
  ageMinutes: number | null;
};

function compactMoney(
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
    ).toFixed(1)}K`;
  }

  return `$${value.toFixed(2)}`;
}

function ageText(
  minutes: number | null,
) {
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

  const hours =
    minutes / 60;

  if (hours < 24) {
    return `${hours.toFixed(
      hours >= 10 ? 0 : 1,
    )}h`;
  }

  return `${(
    hours / 24
  ).toFixed(1)}d`;
}

async function fetchTelegramMarketSnapshot(
  tokenAddress: string,
): Promise<TelegramMarketSnapshot> {
  const empty: TelegramMarketSnapshot = {
    marketCapUsd: null,
    liquidityUsd: null,
    volume5mUsd: null,
    buyPressure: null,
    volumeSpike: null,
    ageMinutes: null,
  };

  try {
    const response = await fetch(
      `https://api.dexscreener.com/latest/dex/tokens/${encodeURIComponent(
        tokenAddress,
      )}`,
      {
        cache: "no-store",
        signal:
          AbortSignal.timeout(
            6_000,
          ),
      },
    );

    if (!response.ok) {
      return empty;
    }

    const body =
      (await response.json()) as {
        pairs?: Array<{
          chainId?: string;
          marketCap?: number;
          fdv?: number;
          pairCreatedAt?: number;
          liquidity?: {
            usd?: number;
          };
          volume?: {
            m5?: number;
            h1?: number;
          };
          txns?: {
            m5?: {
              buys?: number;
              sells?: number;
            };
          };
        }>;
      };

    const pairs =
      (body.pairs ?? [])
        .filter(
          (pair) =>
            pair.chainId ===
            "solana",
        )
        .sort(
          (a, b) =>
            Number(
              b.liquidity?.usd ??
                0,
            ) -
            Number(
              a.liquidity?.usd ??
                0,
            ),
        );

    const pair =
      pairs[0];

    if (!pair) {
      return empty;
    }

    const buys =
      Number(
        pair.txns?.m5?.buys ??
          0,
      );

    const sells =
      Number(
        pair.txns?.m5?.sells ??
          0,
      );

    const totalTxns =
      buys + sells;

    const volume5m =
      Number(
        pair.volume?.m5 ??
          0,
      );

    const volume1h =
      Number(
        pair.volume?.h1 ??
          0,
      );

    const baseline5m =
      volume1h > 0
        ? volume1h / 12
        : 0;

    const createdAt =
      Number(
        pair.pairCreatedAt ??
          0,
      );

    return {
      marketCapUsd:
        Number.isFinite(
          Number(
            pair.marketCap ??
              pair.fdv,
          ),
        )
          ? Number(
              pair.marketCap ??
                pair.fdv,
            )
          : null,

      liquidityUsd:
        Number.isFinite(
          Number(
            pair.liquidity?.usd,
          ),
        )
          ? Number(
              pair.liquidity?.usd,
            )
          : null,

      volume5mUsd:
        Number.isFinite(
          volume5m,
        )
          ? volume5m
          : null,

      buyPressure:
        totalTxns > 0
          ? (buys /
              totalTxns) *
            100
          : null,

      volumeSpike:
        baseline5m > 0
          ? volume5m /
            baseline5m
          : null,

      ageMinutes:
        createdAt > 0
          ? Math.max(
              0,
              (Date.now() -
                createdAt) /
                60_000,
            )
          : null,
    };
  } catch {
    return empty;
  }
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

  const reasons =
    story?.reasons?.length
      ? story.reasons.slice(0, 4)
      : record.planReason
          .replace(/\s+/g, " ")
          .trim()
          .split(/[.;]/)
          .map((value) => value.trim())
          .filter(Boolean)
          .slice(0, 4);

  const why = [
    story?.buyPressurePct === null ||
    story?.buyPressurePct === undefined
      ? null
      : `Buy Pressure: <b>${story.buyPressurePct.toFixed(0)}%</b>`,
    story?.volumeSpike === null ||
    story?.volumeSpike === undefined
      ? null
      : `Volume Expansion: <b>${story.volumeSpike.toFixed(1)}X</b>`,
    story?.liquidityUsd === null ||
    story?.liquidityUsd === undefined
      ? null
      : `Liquidity: <b>${compactUsd(story.liquidityUsd)}</b>`,
    story?.priceChange5m === null ||
    story?.priceChange5m === undefined
      ? null
      : `5m Momentum: <b>${pct(story.priceChange5m)}</b>`,
  ].filter(
    (value): value is string =>
      value !== null,
  );

  return [
    "ðŸš¨ <b>MEMESCOPE CALL</b>",
    "",
    `<b>$${escapeTelegramHtml(record.symbol)}</b> â€” ${escapeTelegramHtml(record.name)}`,
    `<code>${escapeTelegramHtml(publicId)}</code>`,
    "",
    "<b>CALL MC</b>",
    compactUsd(story?.callMarketCapUsd ?? null),
    "",
    "<b>ENTRY</b>",
    money(record.entryPriceUsd),
    "",
    "<b>SIGNAL SCORE</b>",
    `${Math.round(record.scoreAtEntry)} / 100`,
    "",
    "<b>TRACKING</b>",
    "â— LIVE",
    why.length > 0 ? "" : null,
    why.length > 0 ? "<b>WHY IT TRIGGERED</b>" : null,
    ...why,
    reasons.length > 0 ? "" : null,
    reasons.length > 0
      ? reasons
          .map((reason) => `â€¢ ${escapeTelegramHtml(reason)}`)
          .join("\n")
      : null,
    "",
    "<b>CA</b>",
    `<code>${escapeTelegramHtml(record.tokenAddress)}</code>`,
    "",
    "<i>Original call will remain unchanged. MemeScope continues silent live tracking after publication.</i>",
  ]
    .filter(
      (value): value is string =>
        value !== null,
    )
    .join("\n");
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

export async function publishPendingTelegramSignals() {
  if (!telegramConfigured()) {
    return {
      configured: false,
      initialized: false,
      sent: 0,
      edited: 0,
      targetReplies: 0,
    };
  }

  await ensureTelegramPublisherSchema();

  const baseline =
    await initializeTelegramBaseline();

  if (baseline.initialized) {
    return {
      configured: true,
      initialized: true,
      baselineCount:
        baseline.baselineCount,
      sent: 0,
      edited: 0,
      targetReplies: 0,
    };
  }

  const sql =
    sqlClient();

  const { channelId } =
    telegramConfig();

  const rows =
    await sql`
      SELECT
        r.*,
        p.message_id AS telegram_message_id
      FROM memescope_signal_records r
      LEFT JOIN memescope_telegram_posts p
        ON p.signal_record_id = r.id
      WHERE r.opened_at > ${new Date(
        baseline.initializedAt,
      ).toISOString()}
      ORDER BY r.opened_at ASC
      LIMIT 150
    `;

  let sent = 0;

  for (const raw of rows) {
    const row =
      raw as DbRow;

    const record =
      normalizeRecord(row);

    const messageId =
      numOrNull(
        row.telegram_message_id,
      );

    if (messageId === null) {
      const message =
        await telegramSendMessage(
          channelId,
          await channelText(record),
          {
            replyMarkup:
              signalButtons(
                record,
              ),
          },
        );

      await sql`
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
          ${record.id},
          ${record.signalId},
          ${channelId},
          ${message.message_id},
          FALSE,
          NOW(),
          NULL,
          ${record.status},
          ${record.currentGainPercent},
          ${record.peakGainPercent},
          ${record.maxDrawdownPercent}
        )
        ON CONFLICT (signal_record_id)
        DO UPDATE SET
          message_id = COALESCE(
            memescope_telegram_posts.message_id,
            EXCLUDED.message_id
          ),
          channel_id = EXCLUDED.channel_id,
          first_sent_at = COALESCE(
            memescope_telegram_posts.first_sent_at,
            NOW()
          ),
          last_status = EXCLUDED.last_status,
          last_current_gain_pct = EXCLUDED.last_current_gain_pct,
          last_peak_gain_pct = EXCLUDED.last_peak_gain_pct,
          last_drawdown_pct = EXCLUDED.last_drawdown_pct
      `;

      sent += 1;
      continue;
    }

    await sql`
      UPDATE memescope_telegram_posts
      SET
        last_status = ${record.status},
        last_current_gain_pct = ${record.currentGainPercent},
        last_peak_gain_pct = ${record.peakGainPercent},
        last_drawdown_pct = ${record.maxDrawdownPercent}
      WHERE signal_record_id = ${record.id}
    `;
  }

  return {
    configured: true,
    initialized: false,
    sent,
    edited: 0,
    targetReplies: 0,
  };
}

