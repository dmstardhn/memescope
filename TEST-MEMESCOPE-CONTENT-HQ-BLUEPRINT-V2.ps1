$ErrorActionPreference = "Stop"

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

$response = Invoke-RestMethod `
    -Uri "https://memescopes.vercel.app/api/content-hq/process" `
    -Method Post `
    -Headers @{
        Authorization = "Bearer $secret"
    }

$response | ConvertTo-Json -Depth 20
Remove-Variable secret -ErrorAction SilentlyContinue
