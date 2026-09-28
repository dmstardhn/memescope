$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " MemeScope Signal Calls - Buy Rationale" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

$root = (Get-Location).Path
$path = Join-Path $root "src/app/signals/page.tsx"
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (!(Test-Path -LiteralPath $path)) {
    throw "src/app/signals/page.tsx tidak ditemukan."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $root ".backup-signal-buy-rationale-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-Item -LiteralPath $path -Destination (Join-Path $backupDir "signals-page.tsx.bak") -Force

$content = [System.IO.File]::ReadAllText($path)

# ---------------------------------------------------------
# Add deterministic buy-rationale helper before SignalCard.
# ---------------------------------------------------------

$marker = @'
function SignalCard({
'@

if (!$content.Contains($marker)) {
    throw "SignalCard marker tidak ditemukan. Tidak ada file yang diubah."
}

if (!$content.Contains("function buyRationale(")) {
    $helper = @'
function buyRationale(
  signal: SignalCall,
) {
  if (signal.direction === "caution") {
    return {
      summary:
        "This is not a buy setup yet. MemeScope is flagging the token because current activity also carries elevated reversal or liquidity risk.",
      points: signal.caution.length > 0
        ? signal.caution
        : [
            "The current market structure does not meet the conditions for a watch-side setup.",
          ],
    };
  }

  const points: string[] = [];

  if (signal.buyShare5m !== null) {
    const buyPercent = Math.round(
      signal.buyShare5m * 100,
    );

    const sellPercent =
      100 - buyPercent;

    if (buyPercent >= 58) {
      points.push(
        `Buy pressure is dominant: ${buyPercent}% buys versus ${sellPercent}% sells in the latest 5m window.`,
      );
    } else if (buyPercent >= 55) {
      points.push(
        `Buy pressure has an edge: ${buyPercent}% buys versus ${sellPercent}% sells in the latest 5m window.`,
      );
    }
  }

  if (
    signal.volumeSpike5m !== null &&
    signal.volumeSpike5m >= 1.2
  ) {
    points.push(
      `Volume is expanding: the latest 5m pace is ${signal.volumeSpike5m.toFixed(
        2,
      )}x the recent 1h average 5m pace.`,
    );
  }

  if (signal.liquidityUsd >= 50_000) {
    points.push(
      `Liquidity is strong enough for this screen at about ${money(
        signal.liquidityUsd,
      )}, reducing some thin-pool execution risk.`,
    );
  } else if (signal.liquidityUsd >= 20_000) {
    points.push(
      `Liquidity passes the setup threshold at about ${money(
        signal.liquidityUsd,
      )}, although execution risk is still higher than deeper pools.`,
    );
  }

  if (
    signal.priceChange5m !== null &&
    signal.priceChange5m > 0 &&
    signal.priceChange5m <= 18
  ) {
    points.push(
      `Short-term price action is positive at ${percent(
        signal.priceChange5m,
      )} over 5m without crossing the engine's main overheated threshold.`,
    );
  }

  if (
    signal.pairAgeMinutes !== null &&
    signal.pairAgeMinutes <= 360
  ) {
    points.push(
      `The pair is still early at roughly ${age(
        signal.pairAgeMinutes,
      )} old, so the setup is being detected during an early activity window.`,
    );
  }

  if (points.length === 0) {
    points.push(...signal.reasons);
  }

  let summary =
    "MemeScope detected a watch-side setup because several short-window conditions are aligned.";

  if (
    signal.buyShare5m !== null &&
    signal.buyShare5m >= 0.58 &&
    signal.volumeSpike5m !== null &&
    signal.volumeSpike5m >= 1.5
  ) {
    summary =
      "The main buy thesis is rising demand: buyers are dominating recent transactions while volume is accelerating.";
  } else if (
    signal.volumeSpike5m !== null &&
    signal.volumeSpike5m >= 2
  ) {
    summary =
      "The main buy thesis is abnormal activity: volume has accelerated sharply and the token is receiving substantially more attention than its recent baseline.";
  } else if (
    signal.buyShare5m !== null &&
    signal.buyShare5m >= 0.56
  ) {
    summary =
      "The main buy thesis is order-flow imbalance: recent transactions currently favor buyers.";
  }

  return {
    summary,
    points,
  };
}

'@

    $content = $content.Replace(
        $marker,
        $helper + $marker
    )
}

# ---------------------------------------------------------
# Add rationale variable inside SignalCard.
# ---------------------------------------------------------

$cardOpen = @'
function SignalCard({
  signal,
}: {
  signal: SignalCall;
}) {
  return (
'@

$cardReplacement = @'
function SignalCard({
  signal,
}: {
  signal: SignalCall;
}) {
  const rationale =
    buyRationale(signal);

  return (
'@

if ($content.Contains($cardOpen)) {
    $content = $content.Replace(
        $cardOpen,
        $cardReplacement
    )
} elseif (!$content.Contains("const rationale =")) {
    throw "SignalCard opening block tidak cocok. Tidak ada file yang diubah."
}

# ---------------------------------------------------------
# Replace old generic reasons block with explicit buy rationale.
# ---------------------------------------------------------

$oldBlock = @'
        <div>
          <div className="mb-2 text-[10px] uppercase tracking-[0.15em] text-zinc-600">
            Why it was called
          </div>

          <div className="space-y-2">
            {signal.reasons.map(
              (reason) => (
                <div
                  key={reason}
                  className="flex gap-2 text-xs leading-5 text-zinc-300"
                >
                  <span className="mt-2 h-1 w-1 shrink-0 rounded-full bg-emerald-300" />
                  {reason}
                </div>
              ),
            )}
          </div>
        </div>
'@

$newBlock = @'
        <div>
          <div className="mb-2 text-[10px] uppercase tracking-[0.15em] text-zinc-600">
            {signal.direction === "watch"
              ? "Why this BUY setup appeared"
              : "Why this is NOT a BUY yet"}
          </div>

          <div
            className={`mb-3 rounded-xl border p-3 text-xs leading-5 ${
              signal.direction === "watch"
                ? "border-emerald-400/15 bg-emerald-400/[0.04] text-emerald-100/80"
                : "border-amber-400/15 bg-amber-400/[0.04] text-amber-100/80"
            }`}
          >
            {rationale.summary}
          </div>

          <div className="space-y-2">
            {rationale.points.map(
              (reason) => (
                <div
                  key={reason}
                  className="flex gap-2 text-xs leading-5 text-zinc-300"
                >
                  <span
                    className={`mt-2 h-1 w-1 shrink-0 rounded-full ${
                      signal.direction === "watch"
                        ? "bg-emerald-300"
                        : "bg-amber-300"
                    }`}
                  />
                  {reason}
                </div>
              ),
            )}
          </div>

          {signal.direction === "watch" && (
            <div className="mt-3 text-[10px] leading-4 text-zinc-700">
              Setup rationale only. Signal score ranks rule matches; it is not a win probability or guaranteed entry.
            </div>
          )}
        </div>
'@

if ($content.Contains($oldBlock)) {
    $content = $content.Replace(
        $oldBlock,
        $newBlock
    )
} elseif (!$content.Contains("Why this BUY setup appeared")) {
    throw "Blok 'Why it was called' tidak ditemukan. Tidak ada file yang diubah."
}

[System.IO.File]::WriteAllText(
    $path,
    $content,
    $utf8
)

Remove-Item -Recurse -Force (Join-Path $root ".next") -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Signal BUY rationale added." -ForegroundColor Green
Write-Host "Backup: $backupDir" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "npm run typecheck"
Write-Host "npm run dev"
Write-Host ""
