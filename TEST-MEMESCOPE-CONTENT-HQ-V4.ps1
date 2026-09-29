$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$base = "https://memescopes.vercel.app"
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

Write-Host ""
Write-Host "1) V4 status" -ForegroundColor Cyan
Invoke-RestMethod "$base/api/content-hq-v4/status" | ConvertTo-Json -Depth 8

Write-Host ""
Write-Host "2) Trigger one content pass" -ForegroundColor Cyan
Invoke-RestMethod "$base/api/content-hq-v4/process" -Headers @{Authorization="Bearer $secret"} | ConvertTo-Json -Depth 8

Write-Host ""
Write-Host "3) V4 status after process" -ForegroundColor Cyan
Invoke-RestMethod "$base/api/content-hq-v4/status" | ConvertTo-Json -Depth 8

Write-Host ""
Write-Host "4) Telegram admin test" -ForegroundColor Yellow
Write-Host "Open your administrator bot and send: /contenthq"
Write-Host "You should see Status, Manual Approval and Reset Content History."
