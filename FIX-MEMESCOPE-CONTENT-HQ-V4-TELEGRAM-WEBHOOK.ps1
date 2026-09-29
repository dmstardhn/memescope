$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Get-Location).Path
$path = Join-Path $root "src\app\api\telegram\webhook\route.ts"

if (!(Test-Path -LiteralPath $path)) {
    throw "Telegram webhook route not found: $path"
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
$text = [System.IO.File]::ReadAllText($path)

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $env:TEMP "MemeScope-V4-TelegramWebhook-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-Item -LiteralPath $path -Destination (Join-Path $backupDir "route.ts") -Force

Write-Host ""
Write-Host "MemeScope Content HQ V4 - Telegram webhook patch" -ForegroundColor Cyan
Write-Host "Backup: $backupDir" -ForegroundColor DarkGray
Write-Host ""

# Idempotency: if the handler call already exists, do nothing.
if ($text.Contains("tryHandleContentHqAdminRequest(")) {
    Write-Host "Webhook V4 handler is already present. Nothing to patch." -ForegroundColor Yellow
    exit 0
}

# Add import safely.
$importLine = 'import { tryHandleContentHqAdminRequest } from "@/lib/content-hq-v4/telegram-admin";'

if (!$text.Contains($importLine)) {
    $firstImport = $text.IndexOf("import ")

    if ($firstImport -ge 0) {
        $text = $text.Insert($firstImport, $importLine + "`r`n")
    }
    else {
        # Preserve a possible top-level directive such as "use server";
        $directive = [regex]::Match($text, '^\s*["'']use [^"'']+["''];?\s*')
        if ($directive.Success) {
            $insertAt = $directive.Index + $directive.Length
            $text = $text.Insert($insertAt, "`r`n" + $importLine + "`r`n")
        }
        else {
            $text = $importLine + "`r`n" + $text
        }
    }
}

# Support signatures such as:
# POST(request: Request)
# POST(request: NextRequest)
# POST(req: Request)
# POST(req: NextRequest): Promise<Response>
# POST(request)
$pattern = 'export\s+async\s+function\s+POST\s*\((?<params>[\s\S]*?)\)\s*(?::\s*[^{]+)?\{'
$match = [regex]::Match($text, $pattern)

if (!$match.Success) {
    throw "Could not identify the POST handler safely. No changes were written. Backup: $backupDir"
}

$params = $match.Groups["params"].Value.Trim()

# Get the first parameter variable name.
$paramMatch = [regex]::Match($params, '^\s*(?<name>[A-Za-z_$][A-Za-z0-9_$]*)')
if (!$paramMatch.Success) {
    throw "Could not identify the POST request parameter. No changes were written. Backup: $backupDir"
}

$requestVar = $paramMatch.Groups["name"].Value

$insertAt = $match.Index + $match.Length

$snippet = @"

  const contentHqAdmin = await tryHandleContentHqAdminRequest($requestVar.clone());
  if (contentHqAdmin.handled) {
    return Response.json({ ok: true });
  }

"@

$text = $text.Insert($insertAt, $snippet)

# Guard against accidental duplicate import after insertion.
$importCount = ([regex]::Matches(
    $text,
    [regex]::Escape($importLine)
)).Count

if ($importCount -ne 1) {
    throw "Unexpected Content HQ V4 import count: $importCount. No changes were written."
}

[System.IO.File]::WriteAllText($path, $text, $utf8)

Write-Host "PATCHED src/app/api/telegram/webhook/route.ts" -ForegroundColor Green
Write-Host "Request variable detected: $requestVar" -ForegroundColor Green
Write-Host ""
Write-Host "Verify:" -ForegroundColor Cyan
Write-Host '  Select-String -Path ".\src\app\api\telegram\webhook\route.ts" -Pattern "tryHandleContentHqAdminRequest|contentHqAdmin"'
Write-Host ""
Write-Host "Then run:" -ForegroundColor Cyan
Write-Host "  npm run typecheck"
Write-Host "  npm run build"
