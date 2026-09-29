$ErrorActionPreference = "Stop"

$root = (Get-Location).Path
if (!(Test-Path -LiteralPath (Join-Path $root "package.json"))) {
    throw "Jalankan script ini dari root project memecoin-analyst."
}

$path = Join-Path $root "src\lib\call-story.ts"
if (!(Test-Path -LiteralPath $path)) {
    throw "File tidak ditemukan: $path"
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $env:TEMP "MemeScope-CallStoryExplicitCasts-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-Item -LiteralPath $path -Destination (Join-Path $backupDir "call-story.ts") -Force

$content = [System.IO.File]::ReadAllText($path)

$pattern = '(?s)UPDATE memescope_call_story\s+SET\s+current_price_usd\s*=\s*COALESCE\(.*?updated_at\s*=\s*NOW\(\)\s+WHERE signal_record_id\s*=\s*\$\{record\.id\}'

$matches = [regex]::Matches($content, $pattern)
if ($matches.Count -ne 1) {
    throw "Expected exactly 1 Call Story tracking UPDATE block, found $($matches.Count). No file was changed."
}

$replacement = @'
UPDATE memescope_call_story
        SET
          current_price_usd = COALESCE(${currentPrice}::double precision, current_price_usd),
          current_market_cap_usd = COALESCE(${currentMarketCap}::double precision, current_market_cap_usd),
          call_market_cap_usd = COALESCE(call_market_cap_usd, ${callMarketCap}::double precision),
          peak_price_usd = GREATEST(
            COALESCE(peak_price_usd, 0::double precision),
            COALESCE(${peakPrice}::double precision, 0::double precision)
          ),
          peak_market_cap_usd = GREATEST(
            COALESCE(peak_market_cap_usd, 0::double precision),
            COALESCE(${peakMarketCap}::double precision, 0::double precision)
          ),
          current_multiple = COALESCE(${currentMultiple}::double precision, current_multiple),
          peak_multiple = GREATEST(
            COALESCE(peak_multiple, 1::double precision),
            COALESCE(${peakMultiple}::double precision, 1::double precision)
          ),
          max_drawdown_pct = LEAST(
            COALESCE(max_drawdown_pct, 0::double precision),
            COALESCE(${maxDrawdown}::double precision, 0::double precision)
          ),
          signal_score = GREATEST(
            signal_score,
            ${signal?.signalScore ?? record.scoreAtEntry}::integer
          ),
          buy_pressure_pct = COALESCE(
            buy_pressure_pct,
            ${buyPressurePct}::double precision
          ),
          volume_spike = COALESCE(
            volume_spike,
            ${signal?.volumeSpike5m ?? existing.volumeSpike ?? null}::double precision
          ),
          liquidity_usd = COALESCE(
            ${signal?.liquidityUsd ?? token?.liquidityUsd ?? market?.liquidityUsd ?? null}::double precision,
            liquidity_usd
          ),
          price_change_5m = COALESCE(
            price_change_5m,
            ${signal?.priceChange5m ?? token?.priceChange.m5 ?? null}::double precision
          ),
          pair_age_minutes = COALESCE(
            pair_age_minutes,
            ${signal?.pairAgeMinutes ?? token?.pairAgeMinutes ?? null}::double precision
          ),
          reasons_json = CASE
            WHEN reasons_json = '[]' THEN ${JSON.stringify(reasons)}::text
            ELSE reasons_json
          END,
          updated_at = NOW()
        WHERE signal_record_id = ${record.id}::text
'@

$newContent = [regex]::Replace($content, $pattern, $replacement, 1)

if ($newContent -eq $content) {
    throw "Patch produced no changes."
}

$required = @(
    '${currentPrice}::double precision',
    '${peakPrice}::double precision',
    '${peakMarketCap}::double precision',
    '${peakMultiple}::double precision',
    '${maxDrawdown}::double precision',
    '${signal?.signalScore ?? record.scoreAtEntry}::integer',
    '${record.id}::text'
)

foreach ($marker in $required) {
    if (!$newContent.Contains($marker)) {
        throw "Validation failed before write: $marker"
    }
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($path, $newContent, $utf8)

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " MemeScope Call Story explicit SQL casts installed" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "All numeric parameters in the live tracking UPDATE now have explicit PostgreSQL types." -ForegroundColor Cyan
Write-Host "This specifically prevents decimal token prices such as 0.01011 being inferred as INTEGER." -ForegroundColor Cyan
Write-Host ""
Write-Host "Backup: $backupDir" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next:" -ForegroundColor Yellow
Write-Host " npm run typecheck"
Write-Host " npm run build"
