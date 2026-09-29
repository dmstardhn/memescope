$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Get-Location).Path

if (!(Test-Path -LiteralPath (Join-Path $root "package.json"))) {
    throw "Run this script from the memecoin-analyst project root."
}

$secret = $null
$envPath = Join-Path $root ".env.local"

if (Test-Path -LiteralPath $envPath) {
    $line = Get-Content $envPath |
        Where-Object { $_ -match '^\s*CRON_SECRET\s*=' } |
        Select-Object -First 1

    if ($line) {
        $secret = ($line -replace '^\s*CRON_SECRET\s*=', '').Trim().Trim('"').Trim("'")
    }
}

if (!$secret) {
    $secure = Read-Host "CRON_SECRET" -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)

    try {
        $secret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

$base = "https://memescopes.vercel.app/api/content-hq/matrix-demo"

$info = Invoke-RestMethod `
    -Uri $base `
    -Method Get `
    -Headers @{
        Authorization = "Bearer $secret"
    }

$count = [int]$info.count

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " MemeScope Content HQ - Large Matrix Demo" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Total scenarios: $count" -ForegroundColor Yellow
Write-Host "Each request creates ONE preview to reduce timeout risk." -ForegroundColor DarkGray
Write-Host ""

$results = @()

for ($i = 0; $i -lt $count; $i++) {
    Write-Host "[$($i + 1)/$count] Scenario $i..." -ForegroundColor Cyan

    $body = @{
        index = $i
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod `
            -Uri $base `
            -Method Post `
            -Headers @{
                Authorization = "Bearer $secret"
            } `
            -ContentType "application/json" `
            -Body $body

        $row = [PSCustomObject]@{
            Index = $response.scenarioIndex
            Platform = $response.source
            Type = $response.contentType
            Token = $response.symbol
            Media = $response.mediaGenerated
            Telegram = $response.previewMessageId
            Label = $response.label
            Status = "OK"
        }

        $results += $row

        Write-Host "  $($response.source) | $($response.contentType) | `$$($response.symbol) | media=$($response.mediaGenerated)" -ForegroundColor Green
    }
    catch {
        $message = $_.Exception.Message

        if ($_.ErrorDetails.Message) {
            $message = $_.ErrorDetails.Message
        }

        $results += [PSCustomObject]@{
            Index = $i
            Platform = "-"
            Type = "-"
            Token = "-"
            Media = $false
            Telegram = "-"
            Label = "-"
            Status = "FAILED: $message"
        }

        Write-Host "  FAILED: $message" -ForegroundColor Red
    }

    Start-Sleep -Milliseconds 700
}

Write-Host ""
Write-Host "================ SUMMARY ================" -ForegroundColor Yellow
$results | Format-Table -AutoSize

Write-Host ""
Write-Host "Platform totals:" -ForegroundColor Yellow
$results |
    Where-Object { $_.Status -eq "OK" } |
    Group-Object Platform |
    Select-Object Name, Count |
    Format-Table -AutoSize

Write-Host ""
Write-Host "Content type totals:" -ForegroundColor Yellow
$results |
    Where-Object { $_.Status -eq "OK" } |
    Group-Object Type |
    Select-Object Name, Count |
    Format-Table -AutoSize

Remove-Variable secret -ErrorAction SilentlyContinue
