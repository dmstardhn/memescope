$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Get-Location).Path
$envFile = Join-Path $root ".env.local"
$secret = $null

if (Test-Path $envFile) {
  $line = Get-Content $envFile | Where-Object { $_ -match '^\s*CRON_SECRET\s*=' } | Select-Object -First 1
  if ($line) { $secret = ($line -replace '^\s*CRON_SECRET\s*=','').Trim().Trim('"').Trim("'") }
}

if (!$secret) {
  $secure = Read-Host "CRON_SECRET" -AsSecureString
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { $secret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

$body = @{limit=6} | ConvertTo-Json
$result = Invoke-RestMethod `
  -Uri "https://memescopes.vercel.app/api/content-hq-v4/test-batch" `
  -Method Post `
  -Headers @{Authorization="Bearer $secret"} `
  -ContentType "application/json" `
  -Body $body

$result | ConvertTo-Json -Depth 8

Write-Host ""
Write-Host "Now open:" -ForegroundColor Cyan
Write-Host "  https://memescopes.vercel.app/content-hq"
Write-Host ""
Write-Host "Then open Telegram admin:" -ForegroundColor Cyan
Write-Host "  /contenthq -> Queue"
Write-Host ""
Write-Host "These test items are QUEUED only. They are not published automatically while Manual Approval is ON." -ForegroundColor Yellow