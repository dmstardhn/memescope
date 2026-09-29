$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Get-Location).Path
if (!(Test-Path -LiteralPath (Join-Path $root "package.json"))) {
    throw "Jalankan script ini dari root project memecoin-analyst."
}

$targets = @(
    "src\lib\call-story.ts",
    "src\lib\telegram-publisher.ts",
    "src\lib\telegram.ts",
    "src\app\api\telegram\webhook\route.ts",
    "src\app\api\telegram\content-demo\route.ts",
    "src\app\api\telegram\test\route.ts",
    "src\lib\telegram-photo.ts",
    "src\app\api\telegram\card\test\route.tsx",
    "src\app\calls\page.tsx",
    "src\app\calls\[id]\page.tsx",
    "src\app\api\calls\[id]\card\route.ts"
)

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $env:TEMP "MemeScope-AsciiOutputs-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$utf8 = New-Object System.Text.UTF8Encoding($false)

# Known Unicode / mojibake replacements that should stay readable in ASCII.
$map = [ordered]@{
    "â€”" = "-"
    "â€“" = "-"
    "â€¢" = "-"
    "â†’" = "->"
    "â†" = "<-"
    "â‰¥" = ">="
    "â‰¤" = "<="
    "â€™" = "'"
    "â€˜" = "'"
    "â€œ" = '"'
    "â€" = '"'
    "â€¦" = "..."
    "—" = "-"
    "–" = "-"
    "•" = "-"
    "→" = "->"
    "←" = "<-"
    "≥" = ">="
    "≤" = "<="
    "’" = "'"
    "‘" = "'"
    "“" = '"'
    "”" = '"'
    "…" = "..."
    "×" = "x"
}

$changedFiles = New-Object System.Collections.Generic.List[string]

foreach ($relative in $targets) {
    $path = Join-Path $root $relative

    if (!(Test-Path -LiteralPath $path)) {
        continue
    }

    $content = [System.IO.File]::ReadAllText($path)
    $original = $content

    foreach ($key in $map.Keys) {
        $content = $content.Replace($key, $map[$key])
    }

    # Remove all remaining non-ASCII characters from these user-facing feature files.
    # This deliberately removes emoji and any remaining corrupted UTF-8 fragments.
    $content = [regex]::Replace($content, '[^\x00-\x7F]', '')

    # Clean common spacing artifacts inside quoted/user-facing text without reformatting code.
    $content = $content.Replace("DEMO  ", "DEMO ")
    $content = $content.Replace("  <b>", " <b>")
    $content = $content.Replace("</b>  ", "</b> ")
    $content = $content.Replace("  -  ", " - ")
    $content = $content.Replace(" ->  ", " -> ")

    if ($content -ne $original) {
        $backupPath = Join-Path $backupDir $relative
        $backupParent = Split-Path -Parent $backupPath
        New-Item -ItemType Directory -Force -Path $backupParent | Out-Null
        Copy-Item -LiteralPath $path -Destination $backupPath -Force

        [System.IO.File]::WriteAllText($path, $content, $utf8)
        $changedFiles.Add($relative) | Out-Null
        Write-Host "Cleaned: $relative" -ForegroundColor Green
    } else {
        Write-Host "Already clean: $relative" -ForegroundColor DarkGray
    }
}

# Validate every existing target is now ASCII-only.
$failed = New-Object System.Collections.Generic.List[string]

foreach ($relative in $targets) {
    $path = Join-Path $root $relative
    if (!(Test-Path -LiteralPath $path)) {
        continue
    }

    $check = [System.IO.File]::ReadAllText($path)

    if ([regex]::IsMatch($check, '[^\x00-\x7F]')) {
        $failed.Add($relative) | Out-Null
    }

    if (
        $check.Contains("â€”") -or
        $check.Contains("â€¢") -or
        $check.Contains("ðŸ")
    ) {
        $failed.Add($relative) | Out-Null
    }
}

if ($failed.Count -gt 0) {
    $unique = $failed | Sort-Object -Unique
    throw "ASCII validation failed: $($unique -join ', ')"
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " MemeScope ASCII-safe output patch complete" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Changed files: $($changedFiles.Count)" -ForegroundColor Cyan
Write-Host "All targeted Live Call / Telegram / Content HQ outputs are now ASCII-only." -ForegroundColor Cyan
Write-Host "Emoji, smart punctuation, arrows, bullets and mojibake fragments were removed/replaced." -ForegroundColor Cyan
Write-Host ""
Write-Host "Backup: $backupDir" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next:" -ForegroundColor Yellow
Write-Host " npm run typecheck"
Write-Host " npm run build"
