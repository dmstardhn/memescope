$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

$envPath = Join-Path $root ".env.local"

if (!(Test-Path -LiteralPath $envPath)) {
    throw ".env.local tidak ditemukan di root project."
}

$line = Get-Content -LiteralPath $envPath |
    Where-Object { $_ -match '^\s*CRON_SECRET\s*=' } |
    Select-Object -First 1

if (!$line) {
    throw "CRON_SECRET tidak ditemukan di .env.local."
}

$cronSecret = ($line -replace '^\s*CRON_SECRET\s*=', '').Trim().Trim('"').Trim("'")

if ([string]::IsNullOrWhiteSpace($cronSecret)) {
    throw "CRON_SECRET di .env.local kosong."
}

Write-Host ""
Write-Host "Bootstrapping MemeScope Telegram..." -ForegroundColor Cyan

$output = @(
    curl.exe -sS -w "`nHTTP_STATUS:%{http_code}" -X POST `
        -H "Authorization: Bearer $cronSecret" `
        "https://memescopes.vercel.app/api/telegram/bootstrap"
)

$statusLine = $output |
    Where-Object { $_ -match '^HTTP_STATUS:\d{3}$' } |
    Select-Object -Last 1

if (!$statusLine) {
    Write-Host ($output -join "`n")
    throw "Tidak dapat membaca HTTP status dari bootstrap response."
}

$status = ($statusLine -replace '^HTTP_STATUS:', '').Trim()

$bodyLines = $output |
    Where-Object { $_ -notmatch '^HTTP_STATUS:\d{3}$' }

$body = $bodyLines -join "`n"

Write-Host "HTTP $status"

if ($body) {
    Write-Host $body
}

if ($status -ne "200") {
    throw "Telegram bootstrap gagal. HTTP $status"
}

Write-Host ""
Write-Host "Telegram bootstrap berhasil." -ForegroundColor Green
Write-Host "Sekarang buka bot dan jalankan /settings" -ForegroundColor Green
