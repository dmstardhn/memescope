$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " MemeScope Signal Calls - Buy Rationale v2" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

$root = (Get-Location).Path
$path = Join-Path $root "src/app/signals/page.tsx"
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (!(Test-Path -LiteralPath $path)) {
    throw "src/app/signals/page.tsx tidak ditemukan."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $root ".backup-signal-buy-rationale-v2-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-Item -LiteralPath $path -Destination (Join-Path $backupDir "signals-page.tsx.bak") -Force

$content = [System.IO.File]::ReadAllText($path)

# ---------------------------------------------------------
# 1. Add rationale helper immediately before SignalCard.
#    Regex is newline-agnostic, so CRLF/LF both work.
# ---------------------------------------------------------

if ($content -notmatch 'function\s+buyRationale\s*\(') {

$helper = @'
function buyRationale(
  signal: SignalCall,
) {
  if (signal.direction === "caution") {
    return {
      summary:
        "This is not a BUY setup yet. MemeScope is flagging elevated activity, but the current conditions also carry material reversal or liquidity risk.",
      points:
        signal.caution.length > 0
          ? signal.caution
          : [
              "The current market structure does not meet the rule set for a watch-side setup.",
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
      `Liquidity is relatively deeper for this screen at about ${money(
        signal.liquidityUsd,
      )}.`,
    );
  } else if (signal.liquidityUsd >= 20_000) {
    points.push(
      `Liquidity passes the setup threshold at about ${money(
        signal.liquidityUsd,
      )}, although execution risk remains higher than in deeper pools.`,
    );
  }

  if (
    signal.priceChange5m !== null &&
    signal.priceChange5m > 0 &&
    signal.priceChange5m <= 18
  ) {
    points.push(
      `Short-term momentum is positive at ${percent(
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
    "MemeScope detected a BUY-watch setup because multiple short-window conditions are aligned.";

  if (
    signal.buyShare5m !== null &&
    signal.buyShare5m >= 0.58 &&
    signal.volumeSpike5m !== null &&
    signal.volumeSpike5m >= 1.5
  ) {
    summary =
      "Main thesis: recent order flow favors buyers while volume is accelerating.";
  } else if (
    signal.volumeSpike5m !== null &&
    signal.volumeSpike5m >= 2
  ) {
    summary =
      "Main thesis: activity has accelerated sharply versus the token's recent volume baseline.";
  } else if (
    signal.buyShare5m !== null &&
    signal.buyShare5m >= 0.56
  ) {
    summary =
      "Main thesis: recent transaction flow currently favors buyers.";
  }

  return {
    summary,
    points,
  };
}

'@

    $pattern = '(?m)^function\s+SignalCard\s*\(\{'

    if ($content -notmatch $pattern) {
        throw "SignalCard tidak ditemukan. Tidak ada perubahan ditulis."
    }

    $content = [regex]::Replace(
        $content,
        $pattern,
        $helper + "function SignalCard({",
        1
    )

    Write-Host "Added buyRationale helper." -ForegroundColor Green
}

# ---------------------------------------------------------
# 2. Add `const rationale = buyRationale(signal);`
#    right after the SignalCard function header.
# ---------------------------------------------------------

if ($content -notmatch 'const\s+rationale\s*=\s*buyRationale\s*\(\s*signal\s*\)') {

    $headerPattern = '(?s)(function\s+SignalCard\s*\(\{\s*signal,\s*\}:\s*\{\s*signal:\s*SignalCall;\s*\}\)\s*\{\s*)(return\s*\()'

    if ($content -notmatch $headerPattern) {
        throw "Header SignalCard tidak cocok. Tidak ada perubahan ditulis."
    }

    $content = [regex]::Replace(
        $content,
        $headerPattern,
        '$1const rationale = buyRationale(signal);' + "`r`n`r`n  " + '$2',
        1
    )

    Write-Host "Added rationale variable to SignalCard." -ForegroundColor Green
}

# ---------------------------------------------------------
# 3. Replace only the existing reason column.
#    We stop immediately before the Caution column.
# ---------------------------------------------------------

if ($content -notmatch 'Why this BUY setup appeared') {

$newReasonBlock = @'
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
              Rule-based setup rationale only. Signal score ranks matching conditions; it is not a win probability or guaranteed entry.
            </div>
          )}
        </div>

'@

    $reasonPattern = '(?s)[ \t]*<div>\s*<div className="mb-2 text-\[10px\] uppercase tracking-\[0\.15em\] text-zinc-600">\s*Why it was called\s*</div>\s*<div className="space-y-2">\s*\{signal\.reasons\.map\(\s*\(reason\)\s*=>\s*\(\s*<div\s*key=\{reason\}\s*className="flex gap-2 text-xs leading-5 text-zinc-300"\s*>\s*<span className="mt-2 h-1 w-1 shrink-0 rounded-full bg-emerald-300"\s*/>\s*\{reason\}\s*</div>\s*\),\s*\)\}\s*</div>\s*</div>\s*(?=<div>\s*<div className="mb-2 text-\[10px\] uppercase tracking-\[0\.15em\] text-zinc-600">\s*Caution)'

    $match = [regex]::Match($content, $reasonPattern)

    if (!$match.Success) {
        throw "Blok Why it was called tidak cocok. Tidak ada perubahan ditulis."
    }

    $content = [regex]::Replace(
        $content,
        $reasonPattern,
        "`r`n" + $newReasonBlock,
        1
    )

    Write-Host "Replaced generic reasons with explicit BUY rationale." -ForegroundColor Green
}

# ---------------------------------------------------------
# 4. Write only after all checks passed.
# ---------------------------------------------------------

[System.IO.File]::WriteAllText(
    $path,
    $content,
    $utf8
)

Remove-Item -Recurse -Force (Join-Path $root ".next") -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host " BUY rationale patch complete" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Backup: $backupDir" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "npm run typecheck"
Write-Host "npm run dev"
Write-Host ""
