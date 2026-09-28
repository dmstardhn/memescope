$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " MemeScope Signal Recorder - PostgreSQL Type Fix" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

$root = (Get-Location).Path
$path = Join-Path $root "src/lib/signal-recorder-db.ts"
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (!(Test-Path -LiteralPath $path)) {
    throw "src/lib/signal-recorder-db.ts tidak ditemukan."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $root ".backup-signal-recorder-pgtype-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-Item -LiteralPath $path -Destination (Join-Path $backupDir "signal-recorder-db.ts.bak") -Force

$content = [System.IO.File]::ReadAllText($path)
$original = $content

$old = 'WHEN ${currentPrice} IS NULL THEN'
$new = 'WHEN CAST(${currentPrice} AS DOUBLE PRECISION) IS NULL THEN'

$count = ([regex]::Matches(
    $content,
    [regex]::Escape($old)
)).Count

if ($count -eq 0) {
    if ($content.Contains($new)) {
        Write-Host "PostgreSQL cast fix sudah terpasang." -ForegroundColor Yellow
    } else {
        throw "Marker currentPrice NULL check tidak ditemukan. Tidak ada file yang diubah."
    }
} else {
    $content = $content.Replace($old, $new)

    $remaining = ([regex]::Matches(
        $content,
        [regex]::Escape($old)
    )).Count

    if ($remaining -ne 0) {
        throw "Validasi gagal. Masih ada NULL check tanpa cast."
    }

    [System.IO.File]::WriteAllText(
        $path,
        $content,
        $utf8
    )

    Write-Host "Fixed $count PostgreSQL parameter type checks." -ForegroundColor Green
}

Remove-Item -Recurse -Force (Join-Path $root ".next") -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Why:" -ForegroundColor Cyan
Write-Host 'PostgreSQL could not infer the type of a bind parameter used only in "IS NULL".'
Write-Host 'The patch explicitly casts currentPrice to DOUBLE PRECISION.'
Write-Host ""
Write-Host "Backup: $backupDir" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "npm run typecheck"
Write-Host "npm run build"
Write-Host ""
