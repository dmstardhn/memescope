$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Get-Location).Path
if (!(Test-Path -LiteralPath (Join-Path $root "package.json"))) {
    throw "Run this script from the memecoin-analyst project root."
}

$path = Join-Path $root "src\lib\content-hq.ts"
if (!(Test-Path -LiteralPath $path)) {
    throw "Missing file: $path"
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $env:TEMP "MemeScope-ContentHQ-TimestampFix-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-Item -LiteralPath $path -Destination (Join-Path $backupDir "content-hq.ts") -Force

$content = [System.IO.File]::ReadAllText($path)

$old = @'
    initializedAt:
      row.initialized_at
        ? String(
            row.initialized_at,
          )
        : null,
'@

$new = @'
    initializedAt:
      row.initialized_at
        ? new Date(
            String(
              row.initialized_at,
            ),
          ).toISOString()
        : null,
'@

if (!$content.Contains($old)) {
    throw "Expected initializedAt block not found. No file was changed."
}

$content = $content.Replace($old, $new)

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($path, $content, $utf8)

Write-Host ""
Write-Host "Fixed Content HQ timestamp serialization." -ForegroundColor Green
Write-Host "Backup: $backupDir" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next:" -ForegroundColor Yellow
Write-Host " npm run typecheck"
Write-Host " npm run build"
