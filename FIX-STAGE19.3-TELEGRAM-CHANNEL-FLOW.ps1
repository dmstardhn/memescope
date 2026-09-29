$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " MemeScope Stage 19.3 - Telegram Immutable Signals" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""

$root = (Get-Location).Path
$path = Join-Path $root "src/lib/telegram-publisher.ts"
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (!(Test-Path -LiteralPath $path)) {
    throw "src/lib/telegram-publisher.ts tidak ditemukan."
}

$content = [System.IO.File]::ReadAllText($path)

$requiredMarkers = @(
    "export async function publishPendingTelegramSignals()",
    "memescope_telegram_posts",
    "target_notified_at",
    "telegramSendMessage",
    "targetReply"
)

foreach ($marker in $requiredMarkers) {
    if (!$content.Contains($marker)) {
        throw "Marker tidak ditemukan: $marker. Tidak ada file yang diubah."
    }
}

$start = $content.IndexOf(
    "export async function publishPendingTelegramSignals()"
)

if ($start -lt 0) {
    throw "Publisher function tidak ditemukan."
}

$before = $content.Substring(0, $start)

$newFunction = @'
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
        p.message_id AS telegram_message_id,
        p.target_notified_at AS telegram_target_notified_at,
        p.last_status AS telegram_last_status,
        p.last_current_gain_pct AS telegram_last_current_gain_pct,
        p.last_peak_gain_pct AS telegram_last_peak_gain_pct,
        p.last_drawdown_pct AS telegram_last_drawdown_pct
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
  const edited = 0;
  let targetReplies = 0;

  for (const raw of rows) {
    const row =
      raw as DbRow;

    const record =
      normalizeRecord(row);

    let messageId =
      numOrNull(
        row.telegram_message_id,
      );

    const targetNotified =
      row.telegram_target_notified_at !==
        null &&
      row.telegram_target_notified_at !==
        undefined;

    // Every new signal record gets its own fresh channel message.
    // The original signal message is immutable after it is sent.
    if (messageId === null) {
      const message =
        await telegramSendMessage(
          channelId,
          channelText(record),
          {
            replyMarkup:
              signalButtons(
                record,
              ),
          },
        );

      messageId =
        message.message_id;

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
          ${messageId},
          FALSE,
          NOW(),
          NULL,
          ${record.status},
          ${record.currentGainPercent},
          ${record.peakGainPercent},
          ${record.maxDrawdownPercent}
        )
        ON CONFLICT (
          signal_record_id
        )
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
    } else {
      // Keep tracking data fresh in Neon without editing Telegram.
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

    // No channel update for negative moves or ordinary price changes.
    // Only a confirmed target hit creates one new result message.
    if (
      record.status ===
        "target_hit" &&
      !targetNotified
    ) {
      await telegramSendMessage(
        channelId,
        targetReply(record),
        {
          replyMarkup:
            signalButtons(
              record,
            ),
        },
      );

      await sql`
        UPDATE memescope_telegram_posts
        SET
          target_notified_at = NOW(),
          last_status = ${record.status},
          last_current_gain_pct = ${record.currentGainPercent},
          last_peak_gain_pct = ${record.peakGainPercent},
          last_drawdown_pct = ${record.maxDrawdownPercent}
        WHERE signal_record_id = ${record.id}
      `;

      targetReplies += 1;
    }
  }

  return {
    configured: true,
    initialized: false,
    sent,
    edited,
    targetReplies,
  };
}
'@

$patched =
    $before +
    $newFunction +
    "`r`n"

# telegramEditMessage is no longer needed by the publisher.
if (
    !$patched.Contains("telegramEditMessage(")
) {
    $patched = [regex]::Replace(
        $patched,
        '(?m)^[ \t]*telegramEditMessage,\r?\n',
        '',
        1
    )
}

$validation = @(
    "const edited = 0;",
    "Every new signal record gets its own fresh channel message.",
    "The original signal message is immutable after it is sent.",
    "Only a confirmed target hit creates one new result message.",
    "target_notified_at = NOW()"
)

foreach ($marker in $validation) {
    if (!$patched.Contains($marker)) {
        throw "Validasi gagal: $marker. Tidak ada file yang diubah."
    }
}

if ($patched.Contains("await telegramEditMessage(")) {
    throw "Validasi gagal: publisher masih mengedit pesan Telegram."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $env:TEMP "MemeScope-Stage19.3-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null
Copy-Item -LiteralPath $path -Destination (Join-Path $backup "telegram-publisher.ts.bak") -Force

[System.IO.File]::WriteAllText(
    $path,
    $patched,
    $utf8
)

Remove-Item `
  (Join-Path $root ".next") `
  -Recurse -Force `
  -ErrorAction SilentlyContinue

Write-Host "Updated: src/lib/telegram-publisher.ts" -ForegroundColor Green
Write-Host ""
Write-Host "New channel behavior:" -ForegroundColor Cyan
Write-Host " - New confirmed signal -> NEW Telegram message"
Write-Host " - Original signal message -> NEVER edited"
Write-Host " - Gain below target -> NO update message"
Write-Host " - Negative position -> NO update message"
Write-Host " - Recovers from negative and reaches target -> NEW result message"
Write-Host " - Target result -> sent once only"
Write-Host ""
Write-Host "Backup: $backup" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host " npm run typecheck"
Write-Host " npm run build"
Write-Host ""
