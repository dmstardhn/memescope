$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Get-Location).Path
$path = Join-Path $root "src/app/api/telegram/webhook/route.ts"
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (!(Test-Path -LiteralPath $path)) {
    throw "Webhook route tidak ditemukan: $path"
}

$content = [System.IO.File]::ReadAllText($path)

$markers = @(
    "MEMESCOPE PRESET CONTROL",
    "Age <= 48h",
    "Age <= 24h",
    "Age <= 12h",
    "Age <= 6h",
    "Max age <= "
)

foreach ($marker in $markers) {
    if (!$content.Contains($marker)) {
        throw "Marker tidak ditemukan: $marker. Tidak ada file yang diubah."
    }
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $env:TEMP "MemeScope-Telegram-HTML-Fix-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null
Copy-Item -LiteralPath $path -Destination (Join-Path $backup "route.ts.bak") -Force

$content = $content.Replace("Age <= 48h", "Age &lt;= 48h")
$content = $content.Replace("Age <= 24h", "Age &lt;= 24h")
$content = $content.Replace("Age <= 12h", "Age &lt;= 12h")
$content = $content.Replace("Age <= 6h", "Age &lt;= 6h")
$content = $content.Replace("Max age <= ", "Max age &lt;= ")

if ($content.Contains("Age <= ") -or $content.Contains("Max age <= ")) {
    throw "Validasi gagal: masih ada <= mentah di Telegram HTML."
}

[System.IO.File]::WriteAllText(
    $path,
    $content,
    $utf8
)

Remove-Item (Join-Path $root ".next") -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Telegram HTML parse fix installed." -ForegroundColor Green
Write-Host "Changed raw '<=' text to '&lt;=' inside the preset panel." -ForegroundColor Green
Write-Host "Backup: $backup" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host " npm run typecheck"
Write-Host " npm run build"
Write-Host ""
