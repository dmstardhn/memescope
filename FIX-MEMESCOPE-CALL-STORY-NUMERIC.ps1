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
$backupDir = Join-Path $env:TEMP "MemeScope-CallStoryNumeric-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-Item -LiteralPath $path -Destination (Join-Path $backupDir "call-story.ts") -Force

$content = [System.IO.File]::ReadAllText($path)

$replacements = [ordered]@{
    'COALESCE(${peakPrice}, 0)' = 'COALESCE(${peakPrice}::double precision, 0::double precision)'
    'COALESCE(${peakMarketCap}, 0)' = 'COALESCE(${peakMarketCap}::double precision, 0::double precision)'
    'COALESCE(${peakMultiple}, 1)' = 'COALESCE(${peakMultiple}::double precision, 1::double precision)'
    'COALESCE(${maxDrawdown}, 0)' = 'COALESCE(${maxDrawdown}::double precision, 0::double precision)'
}

$changed = 0

foreach ($old in $replacements.Keys) {
    $new = $replacements[$old]

    if ($content.Contains($new)) {
        Write-Host "Already fixed: $old" -ForegroundColor DarkGray
        continue
    }

    if (!$content.Contains($old)) {
        throw "Expected source marker not found: $old`nNo file was written."
    }

    $content = $content.Replace($old, $new)
    $changed++
}

if ($changed -gt 0) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $content, $utf8)
}

$check = [System.IO.File]::ReadAllText($path)

$required = @(
    'COALESCE(${peakPrice}::double precision, 0::double precision)',
    'COALESCE(${peakMarketCap}::double precision, 0::double precision)',
    'COALESCE(${peakMultiple}::double precision, 1::double precision)',
    'COALESCE(${maxDrawdown}::double precision, 0::double precision)'
)

foreach ($marker in $required) {
    if (!$check.Contains($marker)) {
        throw "Validation failed after write: $marker"
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " MemeScope Call Story numeric SQL fix installed" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Fixed PostgreSQL parameter inference for:" -ForegroundColor Cyan
Write-Host " - peak_price_usd"
Write-Host " - peak_market_cap_usd"
Write-Host " - peak_multiple"
Write-Host " - max_drawdown_pct"
Write-Host ""
Write-Host "Backup: $backupDir" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next:" -ForegroundColor Yellow
Write-Host " npm run typecheck"
Write-Host " npm run build"
