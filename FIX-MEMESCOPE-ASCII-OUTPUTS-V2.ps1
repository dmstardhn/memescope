$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Get-Location).Path

if (!(Test-Path -LiteralPath (Join-Path $root "package.json"))) {
    throw "Run this script from the memecoin-analyst project root."
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
$backupDir = Join-Path $env:TEMP "MemeScope-AsciiSafe-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$utf8 = New-Object System.Text.UTF8Encoding($false)
$changed = @()

function Replace-Unicode-Punctuation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $result = $Text

    # Common punctuation expressed only by code point so this script stays ASCII-only.
    $result = $result.Replace([string][char]0x2014, "-")   # em dash
    $result = $result.Replace([string][char]0x2013, "-")   # en dash
    $result = $result.Replace([string][char]0x2022, "-")   # bullet
    $result = $result.Replace([string][char]0x2192, "->")  # right arrow
    $result = $result.Replace([string][char]0x2190, "<-")  # left arrow
    $result = $result.Replace([string][char]0x2265, ">=")  # greater/equal
    $result = $result.Replace([string][char]0x2264, "<=")  # less/equal
    $result = $result.Replace([string][char]0x2018, "'")
    $result = $result.Replace([string][char]0x2019, "'")
    $result = $result.Replace([string][char]0x201C, '"')
    $result = $result.Replace([string][char]0x201D, '"')
    $result = $result.Replace([string][char]0x2026, "...")
    $result = $result.Replace([string][char]0x00D7, "x")

    return $result
}

foreach ($relative in $targets) {
    $path = Join-Path $root $relative

    if (!(Test-Path -LiteralPath $path)) {
        Write-Host "Skip missing: $relative" -ForegroundColor DarkGray
        continue
    }

    $original = [System.IO.File]::ReadAllText($path)
    $content = Replace-Unicode-Punctuation -Text $original

    # Strip every remaining non-ASCII character from these user-facing feature files.
    # This removes emoji and mojibake fragments such as corrupted UTF-8 symbols.
    $content = [regex]::Replace($content, '[^\x00-\x7F]', '')

    # Small cleanup for text artifacts after symbol removal.
    $content = $content.Replace("DEMO  ", "DEMO ")
    $content = $content.Replace("  -  ", " - ")
    $content = $content.Replace("  ->  ", " -> ")

    if ($content -ne $original) {
        $backupPath = Join-Path $backupDir $relative
        $backupParent = Split-Path -Parent $backupPath
        New-Item -ItemType Directory -Force -Path $backupParent | Out-Null
        Copy-Item -LiteralPath $path -Destination $backupPath -Force

        [System.IO.File]::WriteAllText($path, $content, $utf8)

        $changed += $relative
        Write-Host "Cleaned: $relative" -ForegroundColor Green
    }
    else {
        Write-Host "Already ASCII-safe: $relative" -ForegroundColor DarkGray
    }
}

$failed = @()

foreach ($relative in $targets) {
    $path = Join-Path $root $relative

    if (!(Test-Path -LiteralPath $path)) {
        continue
    }

    $check = [System.IO.File]::ReadAllText($path)

    if ([regex]::IsMatch($check, '[^\x00-\x7F]')) {
        $failed += $relative
    }
}

if ($failed.Count -gt 0) {
    throw "ASCII validation failed: $($failed -join ', ')"
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " MemeScope ASCII-safe output cleanup complete" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Changed files: $($changed.Count)" -ForegroundColor Cyan
Write-Host "Backup: $backupDir" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next:" -ForegroundColor Yellow
Write-Host " npm run typecheck"
Write-Host " npm run build"
