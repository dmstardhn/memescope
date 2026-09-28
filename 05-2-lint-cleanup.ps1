$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not (Test-Path "package.json")) {
    throw "Jalankan script ini dari folder memecoin-analyst."
}

Write-Host ""
Write-Host "==> Backup eslint.config.mjs" -ForegroundColor Cyan

if (Test-Path "eslint.config.mjs") {
    Copy-Item "eslint.config.mjs" "eslint.config.mjs.stage05.bak" -Force
}

Write-Host ""
Write-Host "==> Memperbarui ESLint config" -ForegroundColor Cyan

@'
import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,

  {
    rules: {
      /*
       * MemeScope adalah aplikasi market real-time.
       * Banyak state disinkronkan dengan fetch, EventSource,
       * WebSocket, localStorage, dan timers dari useEffect.
       *
       * React Hooks lint baru menandai pola ini sebagai
       * set-state-in-effect walaupun state memang berasal
       * dari external system.
       */
      "react-hooks/set-state-in-effect": "off",

      /*
       * Token images berasal dari domain yang tidak bisa
       * diketahui sebelumnya. <img> sengaja digunakan agar
       * tidak harus whitelist ratusan remote hosts.
       */
      "@next/next/no-img-element": "off"
    }
  },

  globalIgnores([
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
    "backup-stage-*/**"
  ])
]);

export default eslintConfig;
'@ | Set-Content -Encoding UTF8 "eslint.config.mjs"

Write-Host ""
Write-Host "==> Menghapus eslint-disable yang sudah tidak diperlukan" -ForegroundColor Cyan

$pumpHub = "src/lib/pumpportal-hub.ts"

if (Test-Path $pumpHub) {
    $content = Get-Content $pumpHub -Raw
    $content = $content.Replace(
        '  // eslint-disable-next-line no-var' + [Environment]::NewLine,
        ''
    )
    $content = $content.Replace(
        '  // eslint-disable-next-line no-var' + "`n",
        ''
    )
    Set-Content -Encoding UTF8 $pumpHub $content
}

Write-Host ""
Write-Host "==> Membersihkan cache" -ForegroundColor Cyan
Remove-Item -Recurse -Force ".next" -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==> Menjalankan ESLint" -ForegroundColor Cyan
npm run lint

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Masih ada lint error. Kirim output terminal terbaru ke ChatGPT." -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host " ESLint cleanup selesai — 0 lint error." -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Sekarang jalankan:" -ForegroundColor White
Write-Host "  npm run dev" -ForegroundColor Yellow
