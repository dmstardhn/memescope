$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Get-Location).Path
if (!(Test-Path -LiteralPath (Join-Path $root "package.json"))) {
    throw "Run from memecoin-analyst project root."
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

$kinds = @(
    "runner",
    "big_runner",
    "moonshot",
    "before_move"
)

foreach ($kind in $kinds) {
    Write-Host ""
    Write-Host "Testing $kind ..." -ForegroundColor Cyan

    $body = @{
        kind = $kind
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod `
            -Uri "https://memescopes.vercel.app/api/content-hq/demo" `
            -Method Post `
            -Headers @{
                Authorization = "Bearer $secret"
            } `
            -ContentType "application/json" `
            -Body $body

        $response | ConvertTo-Json -Depth 20
    }
    catch {
        Write-Host "FAILED: $kind" -ForegroundColor Red

        if ($_.ErrorDetails.Message) {
            Write-Host $_.ErrorDetails.Message
        }
        else {
            Write-Host $_.Exception.Message
        }
    }
}

Remove-Variable secret -ErrorAction SilentlyContinue
