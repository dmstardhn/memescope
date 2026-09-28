$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " MemeScope Stage 14 - Live Market Engine" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

$root = (Get-Location).Path
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )

    $full = Join-Path $root $Path
    $dir = Split-Path -Parent $full

    if ($dir -and !(Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    [System.IO.File]::WriteAllText($full, $Content, $utf8NoBom)
    Write-Host "Updated: $Path" -ForegroundColor Green
}

if (!(Test-Path -LiteralPath (Join-Path $root "package.json"))) {
    throw "package.json not found. Run this from the memecoin-analyst project root."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $root ".backup-stage14-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

foreach ($file in @(
    "src/components/app-shell.tsx",
    "src/app/scanner/page.tsx",
    "src/app/discover/page.tsx",
    "src/app/token/[address]/page.tsx"
)) {
    $full = Join-Path $root $file
    if (Test-Path -LiteralPath $full) {
        $safe = ($file -replace '[\\/]', '__') + ".bak"
        Copy-Item -LiteralPath $full -Destination (Join-Path $backupDir $safe) -Force
    }
}

Write-Host "Backup: $backupDir" -ForegroundColor DarkGray

$file_1 = @'
export type MemeScopeStreamMode =
  | "connecting"
  | "enhanced"
  | "logs-rpc"
  | "reconnecting"
  | "offline";

export type MemeScopeLiveSnapshot = {
  tokenAddress: string;
  poolAddress: string;
  priceUsd: number | null;
  priceSol: number | null;
  solUsd: number | null;
  updatedAt: number;
};

export type MemeScopeLiveTrade = {
  signature: string;
  slot: number | null;
  timestamp: number;
  side: "buy" | "sell";
  tokenAmount: number;
  usdAmount: number | null;
  solAmount: number | null;
  priceUsd: number | null;
  priceSol: number | null;
  maker: string | null;
  estimated: boolean;
  source: "enhanced" | "logs-rpc";
};

export type MemeScopeMarketEvent =
  | {
      type: "status";
      mode: MemeScopeStreamMode;
      message: string;
      at: number;
    }
  | {
      type: "snapshot";
      snapshot: MemeScopeLiveSnapshot;
    }
  | {
      type: "trade";
      trade: MemeScopeLiveTrade;
    };

'@
Write-Utf8NoBom "src/lib/memescope-market-types.ts" $file_1

$file_2 = @'
import WebSocket from "ws";

import type {
  MemeScopeLiveSnapshot,
  MemeScopeLiveTrade,
  MemeScopeMarketEvent,
  MemeScopeStreamMode,
} from "@/lib/memescope-market-types";

const WSOL =
  "So11111111111111111111111111111111111111112";

const USD_STABLES = new Set([
  "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
  "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB",
]);

type JsonRecord = Record<string, unknown>;
type Listener = (event: MemeScopeMarketEvent) => void;

type TokenBalance = {
  accountIndex?: number;
  mint?: string;
  owner?: string;
  uiTokenAmount?: {
    amount?: string;
    decimals?: number;
    uiAmount?: number | null;
    uiAmountString?: string;
  };
};

type NormalizedTransaction = {
  signature: string;
  slot: number | null;
  blockTime: number | null;
  transaction: JsonRecord;
  meta: JsonRecord;
};

function objectValue(value: unknown): JsonRecord {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as JsonRecord)
    : {};
}

function stringValue(value: unknown) {
  return typeof value === "string" ? value : "";
}

function numberValue(value: unknown): number | null {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function arrayValue(value: unknown) {
  return Array.isArray(value) ? value : [];
}

function heliusKey() {
  if (process.env.HELIUS_API_KEY) {
    return process.env.HELIUS_API_KEY;
  }

  for (const value of [
    process.env.SOLANA_RPC_URL,
    process.env.SOLANA_WSS_URL,
  ]) {
    if (!value) continue;

    try {
      const url = new URL(value);
      const key = url.searchParams.get("api-key");
      if (key) return key;
    } catch {
      // Ignore malformed optional env URL.
    }
  }

  return null;
}

function rpcUrl() {
  if (process.env.SOLANA_RPC_URL) {
    return process.env.SOLANA_RPC_URL;
  }

  const key = heliusKey();
  return key
    ? `https://mainnet.helius-rpc.com/?api-key=${encodeURIComponent(key)}`
    : null;
}

function enhancedWsUrl() {
  const key = heliusKey();

  if (key) {
    return `wss://atlas-mainnet.helius-rpc.com/?api-key=${encodeURIComponent(key)}`;
  }

  return process.env.SOLANA_WSS_URL ?? null;
}

function standardWsUrl() {
  if (process.env.SOLANA_WSS_URL) {
    return process.env.SOLANA_WSS_URL;
  }

  const key = heliusKey();
  return key
    ? `wss://mainnet.helius-rpc.com/?api-key=${encodeURIComponent(key)}`
    : null;
}

async function rpc(method: string, params: unknown[]) {
  const url = rpcUrl();

  if (!url) {
    throw new Error("SOLANA_RPC_URL or HELIUS_API_KEY is not configured.");
  }

  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: Date.now(),
      method,
      params,
    }),
    cache: "no-store",
  });

  if (!response.ok) {
    throw new Error(`RPC ${response.status}`);
  }

  const json = (await response.json()) as {
    result?: unknown;
    error?: { message?: string };
  };

  if (json.error) {
    throw new Error(json.error.message ?? "RPC error");
  }

  return json.result;
}

async function getTransaction(signature: string) {
  for (let attempt = 0; attempt < 6; attempt++) {
    try {
      const result = await rpc("getTransaction", [
        signature,
        {
          commitment: "confirmed",
          encoding: "jsonParsed",
          maxSupportedTransactionVersion: 1,
        },
      ]);

      if (result) return result;
    } catch {
      // The log notification can beat HTTP transaction availability.
    }

    await new Promise((resolve) =>
      setTimeout(resolve, 70 * (attempt + 1)),
    );
  }

  return null;
}

function relationId(relationships: JsonRecord, key: string) {
  const relation = objectValue(relationships[key]);
  return stringValue(objectValue(relation.data).id);
}

async function fetchSnapshot(
  tokenAddress: string,
  poolAddress: string,
): Promise<MemeScopeLiveSnapshot> {
  let priceUsd: number | null = null;
  let priceSol: number | null = null;

  try {
    const response = await fetch(
      `https://api.geckoterminal.com/api/v2/networks/solana/pools/${encodeURIComponent(poolAddress)}?include=base_token,quote_token`,
      {
        headers: {
          Accept: "application/json;version=20230203",
        },
        cache: "no-store",
      },
    );

    if (response.ok) {
      const json = (await response.json()) as JsonRecord;
      const data = objectValue(json.data);
      const attributes = objectValue(data.attributes);
      const relationships = objectValue(data.relationships);
      const quoteId = relationId(relationships, "quote_token");
      const tokenIsQuote = quoteId
        .toLowerCase()
        .endsWith(tokenAddress.toLowerCase());

      priceUsd = numberValue(
        tokenIsQuote
          ? attributes.quote_token_price_usd
          : attributes.base_token_price_usd,
      );

      priceSol = numberValue(
        tokenIsQuote
          ? attributes.quote_token_price_native_currency
          : attributes.base_token_price_native_currency,
      );
    }
  } catch {
    // Dex fallback below.
  }

  if (!priceUsd || !priceSol) {
    try {
      const response = await fetch(
        `https://api.dexscreener.com/latest/dex/pairs/solana/${encodeURIComponent(poolAddress)}`,
        { cache: "no-store" },
      );

      if (response.ok) {
        const json = (await response.json()) as {
          pairs?: Array<{
            baseToken?: { address?: string };
            quoteToken?: { address?: string };
            priceUsd?: string | null;
            priceNative?: string | null;
          }>;
        };

        const pair = json.pairs?.[0];

        if (pair) {
          const isBase = pair.baseToken?.address === tokenAddress;
          const isQuote = pair.quoteToken?.address === tokenAddress;
          const native = numberValue(pair.priceNative);

          if (!priceUsd && isBase) {
            priceUsd = numberValue(pair.priceUsd);
          }

          if (!priceSol && native && isBase && pair.quoteToken?.address === WSOL) {
            priceSol = native;
          }

          if (!priceSol && native && isQuote && pair.baseToken?.address === WSOL) {
            priceSol = 1 / native;
          }
        }
      }
    } catch {
      // Snapshot can remain partial; live trades can fill it later.
    }
  }

  return {
    tokenAddress,
    poolAddress,
    priceUsd,
    priceSol,
    solUsd:
      priceUsd && priceSol && priceSol > 0
        ? priceUsd / priceSol
        : null,
    updatedAt: Date.now(),
  };
}

function normalizeTransaction(
  raw: unknown,
  signatureHint = "",
): NormalizedTransaction | null {
  const outer = objectValue(raw);
  const outerTransaction = objectValue(outer.transaction);

  // Helius Enhanced WebSocket: result.transaction = { transaction, meta }
  if (outerTransaction.transaction && outerTransaction.meta) {
    return {
      signature: stringValue(outer.signature) || signatureHint,
      slot: numberValue(outer.slot),
      blockTime: numberValue(outer.blockTime),
      transaction: objectValue(outerTransaction.transaction),
      meta: objectValue(outerTransaction.meta),
    };
  }

  // Standard getTransaction response: { transaction, meta, slot, blockTime }
  if (outer.transaction && outer.meta) {
    const tx = objectValue(outer.transaction);
    const signatures = arrayValue(tx.signatures);

    return {
      signature:
        stringValue(signatures[0]) ||
        stringValue(outer.signature) ||
        signatureHint,
      slot: numberValue(outer.slot),
      blockTime: numberValue(outer.blockTime),
      transaction: tx,
      meta: objectValue(outer.meta),
    };
  }

  return null;
}

function amountOf(balance: TokenBalance | undefined) {
  const ui = balance?.uiTokenAmount;
  if (!ui) return 0;

  const direct =
    numberValue(ui.uiAmountString) ?? numberValue(ui.uiAmount);

  if (direct !== null) return direct;

  const raw = numberValue(ui.amount);
  const decimals = numberValue(ui.decimals);

  if (raw === null || decimals === null) return 0;
  return raw / 10 ** decimals;
}

function ownerMintDeltas(pre: TokenBalance[], post: TokenBalance[]) {
  const before = new Map<string, number>();
  const after = new Map<string, number>();

  for (const item of pre) {
    if (!item.owner || !item.mint) continue;
    const key = `${item.owner}|${item.mint}`;
    before.set(key, (before.get(key) ?? 0) + amountOf(item));
  }

  for (const item of post) {
    if (!item.owner || !item.mint) continue;
    const key = `${item.owner}|${item.mint}`;
    after.set(key, (after.get(key) ?? 0) + amountOf(item));
  }

  const keys = new Set([...before.keys(), ...after.keys()]);

  return Array.from(keys).map((key) => {
    const split = key.lastIndexOf("|");
    return {
      owner: key.slice(0, split),
      mint: key.slice(split + 1),
      delta: (after.get(key) ?? 0) - (before.get(key) ?? 0),
    };
  });
}

function accountKey(value: unknown) {
  if (typeof value === "string") {
    return { pubkey: value, signer: false };
  }

  const row = objectValue(value);
  return {
    pubkey: stringValue(row.pubkey),
    signer: row.signer === true,
  };
}

function parseTrade(
  normalized: NormalizedTransaction,
  tokenAddress: string,
  snapshot: MemeScopeLiveSnapshot,
  source: "enhanced" | "logs-rpc",
): MemeScopeLiveTrade | null {
  if (normalized.meta.err) return null;

  const message = objectValue(normalized.transaction.message);
  const keys = arrayValue(message.accountKeys).map(accountKey);
  const signers = new Set(
    keys.filter((item) => item.signer).map((item) => item.pubkey),
  );

  const pre = (arrayValue(normalized.meta.preTokenBalances) as TokenBalance[]);
  const post = (arrayValue(normalized.meta.postTokenBalances) as TokenBalance[]);
  const deltas = ownerMintDeltas(pre, post);

  const tokenCandidates = deltas
    .filter(
      (item) =>
        item.mint === tokenAddress && Math.abs(item.delta) > 0,
    )
    .sort((a, b) => {
      const aWeight = Math.abs(a.delta) * (signers.has(a.owner) ? 100 : 1);
      const bWeight = Math.abs(b.delta) * (signers.has(b.owner) ? 100 : 1);
      return bWeight - aWeight;
    });

  const target = tokenCandidates[0];
  if (!target) return null;

  const tokenAmount = Math.abs(target.delta);
  if (tokenAmount <= 0) return null;

  const side: "buy" | "sell" = target.delta > 0 ? "buy" : "sell";

  function deltaForMint(mint: string) {
    return (
      deltas.find(
        (item) => item.owner === target.owner && item.mint === mint,
      )?.delta ?? 0
    );
  }

  const wsolDelta = deltaForMint(WSOL);
  let stableDelta = 0;

  for (const mint of USD_STABLES) {
    const value = deltaForMint(mint);
    if (Math.abs(value) > Math.abs(stableDelta)) stableDelta = value;
  }

  let nativeSolDelta = 0;
  const ownerIndex = keys.findIndex((item) => item.pubkey === target.owner);
  const preBalances = arrayValue(normalized.meta.preBalances).map(Number);
  const postBalances = arrayValue(normalized.meta.postBalances).map(Number);
  const fee = numberValue(normalized.meta.fee) ?? 0;

  if (
    ownerIndex >= 0 &&
    Number.isFinite(preBalances[ownerIndex]) &&
    Number.isFinite(postBalances[ownerIndex])
  ) {
    let lamports = postBalances[ownerIndex] - preBalances[ownerIndex];
    if (ownerIndex === 0) lamports += fee;
    nativeSolDelta = lamports / 1_000_000_000;
  }

  let solAmount: number | null = null;
  let usdAmount: number | null = null;
  let priceSol: number | null = null;
  let priceUsd: number | null = null;
  let estimated = false;

  const solDelta = Math.abs(wsolDelta) > 0 ? wsolDelta : nativeSolDelta;

  if (Math.abs(stableDelta) > 0) {
    usdAmount = Math.abs(stableDelta);
    priceUsd = usdAmount / tokenAmount;

    if (snapshot.solUsd && snapshot.solUsd > 0) {
      solAmount = usdAmount / snapshot.solUsd;
      priceSol = priceUsd / snapshot.solUsd;
    }
  } else if (Math.abs(solDelta) > 0) {
    solAmount = Math.abs(solDelta);
    priceSol = solAmount / tokenAmount;

    if (snapshot.solUsd && snapshot.solUsd > 0) {
      usdAmount = solAmount * snapshot.solUsd;
      priceUsd = priceSol * snapshot.solUsd;
    }
  } else {
    estimated = true;
    priceUsd = snapshot.priceUsd;
    priceSol = snapshot.priceSol;

    if (priceUsd) usdAmount = priceUsd * tokenAmount;
    if (priceSol) solAmount = priceSol * tokenAmount;
  }

  if (!priceUsd && !priceSol) return null;

  return {
    signature: normalized.signature,
    slot: normalized.slot,
    timestamp:
      normalized.blockTime && normalized.blockTime > 0
        ? normalized.blockTime * 1000
        : Date.now(),
    side,
    tokenAmount,
    usdAmount,
    solAmount,
    priceUsd,
    priceSol,
    maker: target.owner || null,
    estimated,
    source,
  };
}

class MarketSession {
  readonly key: string;
  readonly tokenAddress: string;
  readonly poolAddress: string;

  private listeners = new Set<Listener>();
  private socket: WebSocket | null = null;
  private stopped = false;
  private enhancedRejected = false;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private cleanupTimer: ReturnType<typeof setTimeout> | null = null;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private mode: MemeScopeStreamMode = "connecting";
  private seen = new Set<string>();
  private pending = new Set<string>();
  private snapshot: MemeScopeLiveSnapshot;

  constructor(tokenAddress: string, poolAddress: string) {
    this.tokenAddress = tokenAddress;
    this.poolAddress = poolAddress;
    this.key = `${tokenAddress}:${poolAddress}`;
    this.snapshot = {
      tokenAddress,
      poolAddress,
      priceUsd: null,
      priceSol: null,
      solUsd: null,
      updatedAt: Date.now(),
    };

    void this.start();
  }

  subscribe(listener: Listener) {
    this.listeners.add(listener);

    if (this.cleanupTimer) {
      clearTimeout(this.cleanupTimer);
      this.cleanupTimer = null;
    }

    listener({
      type: "status",
      mode: this.mode,
      message: this.statusMessage(),
      at: Date.now(),
    });

    listener({ type: "snapshot", snapshot: this.snapshot });

    return () => {
      this.listeners.delete(listener);

      if (this.listeners.size === 0) {
        this.cleanupTimer = setTimeout(() => this.stop(), 60_000);
      }
    };
  }

  private emit(event: MemeScopeMarketEvent) {
    for (const listener of this.listeners) listener(event);
  }

  private statusMessage() {
    if (this.mode === "enhanced") {
      return "Processed transaction stream via Helius Enhanced WebSocket";
    }
    if (this.mode === "logs-rpc") {
      return "Standard Solana logs stream; transaction details follow RPC availability";
    }
    if (this.mode === "reconnecting") return "Reconnecting market stream";
    if (this.mode === "offline") return "Real-time stream unavailable";
    return "Connecting market stream";
  }

  private setMode(mode: MemeScopeStreamMode) {
    this.mode = mode;
    this.emit({
      type: "status",
      mode,
      message: this.statusMessage(),
      at: Date.now(),
    });
  }

  private async start() {
    this.snapshot = await fetchSnapshot(
      this.tokenAddress,
      this.poolAddress,
    );
    this.emit({ type: "snapshot", snapshot: this.snapshot });
    this.connect();
  }

  private connect() {
    if (this.stopped) return;

    const url = this.enhancedRejected ? standardWsUrl() : enhancedWsUrl();

    if (!url) {
      this.setMode("offline");
      return;
    }

    this.setMode(this.socket ? "reconnecting" : "connecting");

    const ws = new WebSocket(url);
    this.socket = ws;
    const enhancedAttempt = !this.enhancedRejected;

    ws.on("open", () => {
      if (this.stopped) {
        ws.close();
        return;
      }

      if (enhancedAttempt) {
        ws.send(
          JSON.stringify({
            jsonrpc: "2.0",
            id: 8101,
            method: "transactionSubscribe",
            params: [
              {
                failed: false,
                vote: false,
                accountInclude: [this.poolAddress],
              },
              {
                commitment: "processed",
                encoding: "jsonParsed",
                transactionDetails: "full",
                showRewards: false,
                maxSupportedTransactionVersion: 1,
              },
            ],
          }),
        );
      } else {
        ws.send(
          JSON.stringify({
            jsonrpc: "2.0",
            id: 8102,
            method: "logsSubscribe",
            params: [
              { mentions: [this.poolAddress] },
              { commitment: "processed" },
            ],
          }),
        );
      }

      this.pingTimer = setInterval(() => {
        if (ws.readyState === WebSocket.OPEN) ws.ping();
      }, 20_000);
    });

    ws.on("message", (raw) => {
      let message: {
        id?: number;
        error?: unknown;
        result?: unknown;
        method?: string;
        params?: { result?: unknown };
      };

      try {
        message = JSON.parse(raw.toString());
      } catch {
        return;
      }

      if (message.id === 8101) {
        if (message.error) {
          this.enhancedRejected = true;
          ws.close();
        } else {
          this.setMode("enhanced");
        }
        return;
      }

      if (message.id === 8102) {
        if (message.error) this.setMode("offline");
        else this.setMode("logs-rpc");
        return;
      }

      if (message.method === "transactionNotification") {
        const result = message.params?.result;
        if (result) void this.handleRaw(result, "enhanced");
        return;
      }

      if (message.method === "logsNotification") {
        const result = objectValue(message.params?.result);
        const value = objectValue(result.value);
        const signature = stringValue(value.signature);
        const err = value.err;

        if (signature && !err) void this.handleSignature(signature);
      }
    });

    ws.on("error", () => {
      // The close handler below controls fallback/reconnect.
    });

    ws.on("close", () => {
      if (this.pingTimer) {
        clearInterval(this.pingTimer);
        this.pingTimer = null;
      }

      if (this.stopped) return;

      this.setMode("reconnecting");
      this.reconnectTimer = setTimeout(() => this.connect(), 700);
    });
  }

  private async handleSignature(signature: string) {
    if (this.seen.has(signature) || this.pending.has(signature)) return;
    this.pending.add(signature);

    try {
      const raw = await getTransaction(signature);
      if (raw) await this.handleRaw(raw, "logs-rpc", signature);
    } finally {
      this.pending.delete(signature);
    }
  }

  private async handleRaw(
    raw: unknown,
    source: "enhanced" | "logs-rpc",
    signatureHint = "",
  ) {
    const normalized = normalizeTransaction(raw, signatureHint);
    if (!normalized) return;

    if (normalized.signature && this.seen.has(normalized.signature)) return;

    const trade = parseTrade(
      normalized,
      this.tokenAddress,
      this.snapshot,
      source,
    );

    if (!trade) return;

    if (trade.signature) {
      this.seen.add(trade.signature);
      if (this.seen.size > 2500) {
        const oldest = this.seen.values().next().value as string | undefined;
        if (oldest) this.seen.delete(oldest);
      }
    }

    if (trade.priceUsd) this.snapshot.priceUsd = trade.priceUsd;
    if (trade.priceSol) this.snapshot.priceSol = trade.priceSol;

    if (trade.priceUsd && trade.priceSol && trade.priceSol > 0) {
      this.snapshot.solUsd = trade.priceUsd / trade.priceSol;
    }

    this.snapshot.updatedAt = Date.now();
    this.emit({ type: "trade", trade });
  }

  private stop() {
    this.stopped = true;

    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    if (this.pingTimer) clearInterval(this.pingTimer);

    if (this.socket && this.socket.readyState < WebSocket.CLOSING) {
      this.socket.close();
    }

    REGISTRY.delete(this.key);
  }
}

declare global {
  var __memescopeMarketRegistry:
    | Map<string, MarketSession>
    | undefined;
}

const REGISTRY =
  globalThis.__memescopeMarketRegistry ?? new Map<string, MarketSession>();

globalThis.__memescopeMarketRegistry = REGISTRY;

export function subscribeMarket(
  tokenAddress: string,
  poolAddress: string,
  listener: Listener,
) {
  const key = `${tokenAddress}:${poolAddress}`;
  let session = REGISTRY.get(key);

  if (!session) {
    session = new MarketSession(tokenAddress, poolAddress);
    REGISTRY.set(key, session);
  }

  return session.subscribe(listener);
}

'@
Write-Utf8NoBom "src/lib/memescope-market-engine.ts" $file_2

$file_3 = @'
import { NextRequest } from "next/server";

import { subscribeMarket } from "@/lib/memescope-market-engine";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function validAddress(value: string) {
  return /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(value);
}

export async function GET(
  request: NextRequest,
  context: { params: Promise<{ address: string }> },
) {
  const { address } = await context.params;
  const pool = request.nextUrl.searchParams.get("pool");

  if (!validAddress(address) || !pool || !validAddress(pool)) {
    return new Response(
      JSON.stringify({ error: "Valid token and pool addresses are required." }),
      {
        status: 400,
        headers: { "Content-Type": "application/json" },
      },
    );
  }

  const encoder = new TextEncoder();
  let unsubscribe: (() => void) | null = null;
  let heartbeat: ReturnType<typeof setInterval> | null = null;
  let closed = false;

  const stream = new ReadableStream({
    start(controller) {
      const send = (event: string, payload: unknown) => {
        if (closed) return;
        controller.enqueue(
          encoder.encode(
            `event: ${event}\ndata: ${JSON.stringify(payload)}\n\n`,
          ),
        );
      };

      unsubscribe = subscribeMarket(address, pool, (event) => {
        send(event.type, event);
      });

      heartbeat = setInterval(() => {
        send("heartbeat", { at: Date.now() });
      }, 15_000);

      request.signal.addEventListener(
        "abort",
        () => {
          if (closed) return;
          closed = true;
          if (heartbeat) clearInterval(heartbeat);
          unsubscribe?.();
          try {
            controller.close();
          } catch {
            // Already closed.
          }
        },
        { once: true },
      );
    },

    cancel() {
      closed = true;
      if (heartbeat) clearInterval(heartbeat);
      unsubscribe?.();
    },
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
      "X-Accel-Buffering": "no",
    },
  });
}

'@
Write-Utf8NoBom "src/app/api/live-market/solana/[address]/route.ts" $file_3

$file_4 = @'
"use client";

import {
  CandlestickSeries,
  ColorType,
  createChart,
  HistogramSeries,
  type IChartApi,
  type ISeriesApi,
  type UTCTimestamp,
} from "lightweight-charts";
import { useEffect, useRef } from "react";

export type MemeScopeDisplayCandle = {
  time: number;
  open: number;
  high: number;
  low: number;
  close: number;
  volume: number;
};

export function MemeScopeLiveChart({
  candles,
  seriesKey,
  height = 350,
}: {
  candles: MemeScopeDisplayCandle[];
  seriesKey: string;
  height?: number;
}) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const chartRef = useRef<IChartApi | null>(null);
  const candleRef = useRef<ISeriesApi<"Candlestick"> | null>(null);
  const volumeRef = useRef<ISeriesApi<"Histogram"> | null>(null);
  const lastTimeRef = useRef<number | null>(null);
  const countRef = useRef(0);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const chart = createChart(container, {
      width: container.clientWidth,
      height,
      layout: {
        background: { type: ColorType.Solid, color: "#090b0f" },
        textColor: "#71717a",
        attributionLogo: true,
      },
      grid: {
        vertLines: { color: "#12151b" },
        horzLines: { color: "#12151b" },
      },
      rightPriceScale: {
        borderColor: "#252932",
        minimumWidth: 70,
        scaleMargins: { top: 0.08, bottom: 0.22 },
      },
      timeScale: {
        borderColor: "#252932",
        timeVisible: true,
        secondsVisible: false,
        rightOffset: 4,
        barSpacing: 7,
      },
      crosshair: {
        vertLine: { color: "#52525b" },
        horzLine: { color: "#52525b" },
      },
    });

    chartRef.current = chart;

    candleRef.current = chart.addSeries(CandlestickSeries, {
      upColor: "#34d399",
      downColor: "#f87171",
      borderVisible: false,
      wickUpColor: "#34d399",
      wickDownColor: "#f87171",
      priceLineVisible: true,
      lastValueVisible: true,
    });

    volumeRef.current = chart.addSeries(HistogramSeries, {
      priceFormat: { type: "volume" },
      priceScaleId: "volume",
    });

    volumeRef.current.priceScale().applyOptions({
      scaleMargins: { top: 0.78, bottom: 0 },
    });

    lastTimeRef.current = null;
    countRef.current = 0;

    const observer = new ResizeObserver((entries) => {
      const entry = entries[0];
      if (entry) chart.applyOptions({ width: entry.contentRect.width });
    });

    observer.observe(container);

    return () => {
      observer.disconnect();
      chart.remove();
      chartRef.current = null;
      candleRef.current = null;
      volumeRef.current = null;
    };
  }, [height, seriesKey]);

  useEffect(() => {
    const candleSeries = candleRef.current;
    const volumeSeries = volumeRef.current;
    const chart = chartRef.current;

    if (!candleSeries || !volumeSeries || !chart) return;

    const clean = candles.filter(
      (item) =>
        Number.isFinite(item.time) &&
        Number.isFinite(item.open) &&
        Number.isFinite(item.high) &&
        Number.isFinite(item.low) &&
        Number.isFinite(item.close) &&
        item.open > 0 &&
        item.high > 0 &&
        item.low > 0 &&
        item.close > 0,
    );

    if (clean.length === 0) {
      candleSeries.setData([]);
      volumeSeries.setData([]);
      lastTimeRef.current = null;
      countRef.current = 0;
      return;
    }

    const last = clean[clean.length - 1];
    const candlePoint = {
      time: last.time as UTCTimestamp,
      open: last.open,
      high: last.high,
      low: last.low,
      close: last.close,
    };
    const volumePoint = {
      time: last.time as UTCTimestamp,
      value: last.volume,
      color:
        last.close >= last.open
          ? "rgba(52, 211, 153, 0.42)"
          : "rgba(248, 113, 113, 0.42)",
    };

    const incremental =
      lastTimeRef.current !== null &&
      (countRef.current === clean.length ||
        countRef.current + 1 === clean.length) &&
      last.time >= lastTimeRef.current;

    if (incremental) {
      candleSeries.update(candlePoint);
      volumeSeries.update(volumePoint);
    } else {
      candleSeries.setData(
        clean.map((item) => ({
          time: item.time as UTCTimestamp,
          open: item.open,
          high: item.high,
          low: item.low,
          close: item.close,
        })),
      );
      volumeSeries.setData(
        clean.map((item) => ({
          time: item.time as UTCTimestamp,
          value: item.volume,
          color:
            item.close >= item.open
              ? "rgba(52, 211, 153, 0.42)"
              : "rgba(248, 113, 113, 0.42)",
        })),
      );
      chart.timeScale().fitContent();
    }

    lastTimeRef.current = last.time;
    countRef.current = clean.length;
  }, [candles]);

  return <div ref={containerRef} className="mx-auto w-full max-w-[980px]" />;
}

'@
Write-Utf8NoBom "src/components/memescope-live-chart.tsx" $file_4

$file_5 = @'
"use client";

import Link from "next/link";
import {
  Bookmark,
  BookmarkCheck,
  Copy,
  ExternalLink,
  Maximize2,
  RefreshCw,
  X,
} from "lucide-react";
import { useEffect, useMemo, useState } from "react";

import {
  MemeScopeLiveChart,
  type MemeScopeDisplayCandle,
} from "@/components/memescope-live-chart";
import type {
  MemeScopeLiveSnapshot,
  MemeScopeLiveTrade,
  MemeScopeStreamMode,
} from "@/lib/memescope-market-types";
import type {
  TokenTerminalResponse,
  TokenTerminalTimeframe,
} from "@/lib/token-terminal-types";

const WATCHLIST_KEY = "memescope-token-watchlist";
const TIMEFRAMES: TokenTerminalTimeframe[] = ["1m", "5m", "15m", "1h", "4h", "1d"];

type Metric = "price" | "mcap";
type Quote = "usd" | "sol";

function timeframeSeconds(timeframe: TokenTerminalTimeframe) {
  if (timeframe === "1m") return 60;
  if (timeframe === "5m") return 300;
  if (timeframe === "15m") return 900;
  if (timeframe === "1h") return 3600;
  if (timeframe === "4h") return 14400;
  return 86400;
}

function money(value: number | null | undefined) {
  if (value === null || value === undefined || !Number.isFinite(value)) return "N/A";
  if (Math.abs(value) >= 1_000_000_000) return `$${(value / 1_000_000_000).toFixed(2)}B`;
  if (Math.abs(value) >= 1_000_000) return `$${(value / 1_000_000).toFixed(2)}M`;
  if (Math.abs(value) >= 1_000) return `$${(value / 1_000).toFixed(1)}K`;
  if (Math.abs(value) >= 1) return `$${value.toFixed(3)}`;
  return `$${value.toPrecision(5)}`;
}

function solText(value: number | null | undefined) {
  if (value === null || value === undefined || !Number.isFinite(value)) return "N/A";
  if (Math.abs(value) >= 1_000_000) return `${(value / 1_000_000).toFixed(2)}M SOL`;
  if (Math.abs(value) >= 1_000) return `${(value / 1_000).toFixed(2)}K SOL`;
  if (Math.abs(value) >= 1) return `${value.toFixed(3)} SOL`;
  return `${value.toPrecision(5)} SOL`;
}

function short(value: string) {
  if (value.length <= 13) return value;
  return `${value.slice(0, 5)}...${value.slice(-4)}`;
}

function clock(timestamp: number) {
  return new Date(timestamp).toLocaleTimeString("en-US", {
    hour12: false,
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

function streamLabel(mode: MemeScopeStreamMode) {
  if (mode === "enhanced") return "LIVE PROCESSED";
  if (mode === "logs-rpc") return "LIVE RPC";
  if (mode === "reconnecting") return "RECONNECTING";
  if (mode === "offline") return "OFFLINE";
  return "CONNECTING";
}

export function TokenMarketTerminal({
  address,
  mode = "page",
  onClose,
}: {
  address: string;
  mode?: "page" | "modal";
  onClose?: () => void;
}) {
  const [data, setData] = useState<TokenTerminalResponse | null>(null);
  const [timeframe, setTimeframe] = useState<TokenTerminalTimeframe>("5m");
  const [pool, setPool] = useState<string | null>(null);
  const [metric, setMetric] = useState<Metric>("price");
  const [quote, setQuote] = useState<Quote>("usd");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [streamMode, setStreamMode] = useState<MemeScopeStreamMode>("connecting");
  const [streamMessage, setStreamMessage] = useState("Connecting real-time stream");
  const [snapshot, setSnapshot] = useState<MemeScopeLiveSnapshot | null>(null);
  const [liveTrades, setLiveTrades] = useState<MemeScopeLiveTrade[]>([]);
  const [supply, setSupply] = useState<number | null>(null);
  const [saved, setSaved] = useState(false);

  async function load(nextTf = timeframe, nextPool = pool) {
    setLoading(true);

    try {
      const query = new URLSearchParams({ tf: nextTf });
      if (nextPool) query.set("pool", nextPool);

      const response = await fetch(
        `/api/token-terminal/solana/${address}?${query.toString()}`,
        { cache: "no-store" },
      );
      const result = (await response.json()) as TokenTerminalResponse | { error?: string };

      if (!response.ok) {
        throw new Error("error" in result ? result.error : "Token market data failed.");
      }

      const terminal = result as TokenTerminalResponse;
      setData(terminal);
      setPool(terminal.selectedPool.address);
      setError("");
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : "Token market data failed.");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    setData(null);
    setPool(null);
    setSnapshot(null);
    setLiveTrades([]);
    setSupply(null);
    setStreamMode("connecting");
    void load("5m", null);

    void fetch(`/api/risk/solana/${address}`, { cache: "no-store" })
      .then(async (response) => {
        if (!response.ok) return null;
        return (await response.json()) as { supply?: number };
      })
      .then((report) => {
        if (report && Number.isFinite(report.supply) && (report.supply ?? 0) > 0) {
          setSupply(report.supply ?? null);
        }
      })
      .catch(() => undefined);
  }, [address]);

  useEffect(() => {
    try {
      const raw = localStorage.getItem(WATCHLIST_KEY);
      const parsed = raw ? (JSON.parse(raw) as unknown) : [];
      setSaved(Array.isArray(parsed) && parsed.includes(address));
    } catch {
      setSaved(false);
    }
  }, [address]);

  useEffect(() => {
    const selectedPool = data?.selectedPool.address;
    if (!selectedPool) return;

    setLiveTrades([]);
    setSnapshot(null);
    setStreamMode("connecting");

    const source = new EventSource(
      `/api/live-market/solana/${address}?pool=${encodeURIComponent(selectedPool)}`,
    );

    const onStatus = (event: MessageEvent) => {
      try {
        const parsed = JSON.parse(event.data) as {
          mode: MemeScopeStreamMode;
          message: string;
        };
        setStreamMode(parsed.mode);
        setStreamMessage(parsed.message);
      } catch {
        // Ignore malformed event.
      }
    };

    const onSnapshot = (event: MessageEvent) => {
      try {
        const parsed = JSON.parse(event.data) as { snapshot: MemeScopeLiveSnapshot };
        setSnapshot(parsed.snapshot);
      } catch {
        // Ignore malformed event.
      }
    };

    const onTrade = (event: MessageEvent) => {
      try {
        const parsed = JSON.parse(event.data) as { trade: MemeScopeLiveTrade };
        const trade = parsed.trade;

        setLiveTrades((current) => {
          if (trade.signature && current.some((item) => item.signature === trade.signature)) {
            return current;
          }
          return [trade, ...current].slice(0, 300);
        });

        setSnapshot((current) => {
          if (!current) return current;
          const next = { ...current, updatedAt: Date.now() };
          if (trade.priceUsd) next.priceUsd = trade.priceUsd;
          if (trade.priceSol) next.priceSol = trade.priceSol;
          if (trade.priceUsd && trade.priceSol && trade.priceSol > 0) {
            next.solUsd = trade.priceUsd / trade.priceSol;
          }
          return next;
        });
      } catch {
        // Ignore malformed event.
      }
    };

    source.addEventListener("status", onStatus as EventListener);
    source.addEventListener("snapshot", onSnapshot as EventListener);
    source.addEventListener("trade", onTrade as EventListener);
    source.onerror = () => {
      setStreamMode("reconnecting");
      setStreamMessage("Browser stream reconnecting");
    };

    return () => source.close();
  }, [address, data?.selectedPool.address]);

  const solUsd = snapshot?.solUsd ?? null;
  const priceUsd = snapshot?.priceUsd ?? data?.selectedPool.priceUsd ?? null;
  const priceSol = snapshot?.priceSol ?? (priceUsd && solUsd ? priceUsd / solUsd : null);

  const effectiveSupply = useMemo(() => {
    if (supply && supply > 0) return supply;
    const basePrice = data?.selectedPool.priceUsd;
    const cap = data?.selectedPool.marketCapUsd ?? data?.selectedPool.fdvUsd;
    return basePrice && basePrice > 0 && cap && cap > 0 ? cap / basePrice : null;
  }, [data, supply]);

  const displayCandles = useMemo(() => {
    const output = new Map<number, MemeScopeDisplayCandle>();
    if (!data) return [];

    const quoteScale = quote === "usd" ? 1 : solUsd && solUsd > 0 ? 1 / solUsd : null;
    const valueScale =
      quoteScale === null
        ? null
        : metric === "price"
          ? quoteScale
          : effectiveSupply
            ? quoteScale * effectiveSupply
            : null;

    if (valueScale !== null) {
      for (const item of data.candles) {
        output.set(item.time, {
          time: item.time,
          open: item.open * valueScale,
          high: item.high * valueScale,
          low: item.low * valueScale,
          close: item.close * valueScale,
          volume:
            quote === "usd"
              ? item.volume
              : solUsd && solUsd > 0
                ? item.volume / solUsd
                : 0,
        });
      }
    }

    const bucketSize = timeframeSeconds(timeframe);

    for (const trade of liveTrades.slice().reverse()) {
      const tradePrice = quote === "usd" ? trade.priceUsd : trade.priceSol;
      if (!tradePrice || tradePrice <= 0) continue;

      const value =
        metric === "price"
          ? tradePrice
          : effectiveSupply
            ? tradePrice * effectiveSupply
            : null;
      if (!value || value <= 0) continue;

      const bucket = Math.floor(trade.timestamp / 1000 / bucketSize) * bucketSize;
      const volume = quote === "usd" ? trade.usdAmount ?? 0 : trade.solAmount ?? 0;
      const current = output.get(bucket);

      if (!current) {
        output.set(bucket, {
          time: bucket,
          open: value,
          high: value,
          low: value,
          close: value,
          volume,
        });
      } else {
        current.high = Math.max(current.high, value);
        current.low = Math.min(current.low, value);
        current.close = value;
        current.volume += volume;
      }
    }

    return Array.from(output.values()).sort((a, b) => a.time - b.time).slice(-280);
  }, [data, effectiveSupply, liveTrades, metric, quote, solUsd, timeframe]);

  const transactions = useMemo(() => {
    const seen = new Set<string>();
    const rows: Array<{
      key: string;
      timestamp: number;
      side: "buy" | "sell" | "unknown";
      usd: number | null;
      sol: number | null;
      priceUsd: number | null;
      priceSol: number | null;
      maker: string | null;
      signature: string;
      live: boolean;
      estimated: boolean;
    }> = [];

    for (const trade of liveTrades) {
      const key = trade.signature || `${trade.timestamp}-${trade.tokenAmount}`;
      seen.add(key);
      rows.push({
        key,
        timestamp: trade.timestamp,
        side: trade.side,
        usd: trade.usdAmount,
        sol: trade.solAmount,
        priceUsd: trade.priceUsd,
        priceSol: trade.priceSol,
        maker: trade.maker,
        signature: trade.signature,
        live: true,
        estimated: trade.estimated,
      });
    }

    for (const trade of data?.trades ?? []) {
      const key = trade.txHash || `${trade.timestamp}-${trade.volumeUsd}`;
      if (seen.has(key)) continue;
      rows.push({
        key,
        timestamp: trade.timestamp,
        side: trade.kind,
        usd: trade.volumeUsd,
        sol: solUsd && solUsd > 0 ? trade.volumeUsd / solUsd : null,
        priceUsd: trade.priceUsd,
        priceSol: trade.priceUsd && solUsd ? trade.priceUsd / solUsd : null,
        maker: trade.maker,
        signature: trade.txHash,
        live: false,
        estimated: false,
      });
    }

    return rows.sort((a, b) => b.timestamp - a.timestamp).slice(0, 180);
  }, [data, liveTrades, solUsd]);

  const currentValue =
    metric === "price"
      ? quote === "usd"
        ? priceUsd
        : priceSol
      : effectiveSupply
        ? quote === "usd"
          ? priceUsd
            ? priceUsd * effectiveSupply
            : null
          : priceSol
            ? priceSol * effectiveSupply
            : null
        : null;

  function toggleWatchlist() {
    let values: string[] = [];
    try {
      const raw = localStorage.getItem(WATCHLIST_KEY);
      const parsed = raw ? (JSON.parse(raw) as unknown) : [];
      if (Array.isArray(parsed)) {
        values = parsed.filter((item): item is string => typeof item === "string");
      }
    } catch {
      values = [];
    }

    const exists = values.includes(address);
    const next = exists
      ? values.filter((item) => item !== address)
      : Array.from(new Set([...values, address]));

    localStorage.setItem(WATCHLIST_KEY, JSON.stringify(next));
    setSaved(!exists);
  }

  async function switchTimeframe(next: TokenTerminalTimeframe) {
    setTimeframe(next);
    await load(next, pool);
  }

  async function switchPool(next: string) {
    setPool(next);
    await load(timeframe, next);
  }

  const main = (
    <div
      className={
        mode === "modal"
          ? "flex max-h-[90vh] w-full flex-col overflow-hidden rounded-2xl border border-white/10 bg-[#080a0f] shadow-2xl"
          : "mx-auto w-full max-w-[1500px] px-3 py-4 lg:px-5"
      }
    >
      <header
        className={`flex flex-wrap items-center justify-between gap-3 ${
          mode === "modal" ? "border-b border-white/5 px-4 py-3" : "mb-3"
        }`}
      >
        <div className="flex min-w-0 items-center gap-3">
          {data?.token.imageUrl ? (
            <img
              src={data.token.imageUrl}
              alt=""
              className="h-10 w-10 rounded-full border border-white/10 object-cover"
            />
          ) : (
            <div className="flex h-10 w-10 items-center justify-center rounded-full border border-white/10 bg-white/5 text-xs font-bold text-zinc-500">
              {data?.token.symbol?.slice(0, 2) ?? "?"}
            </div>
          )}

          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <span className="text-lg font-semibold text-white">
                {data?.token.symbol ?? "Loading"}
              </span>
              <span className="max-w-[240px] truncate text-xs text-zinc-600">
                {data?.token.name ?? ""}
              </span>
              <span
                title={streamMessage}
                className={`rounded-full border px-2 py-0.5 text-[9px] font-medium ${
                  streamMode === "enhanced" || streamMode === "logs-rpc"
                    ? "border-emerald-400/20 bg-emerald-400/[0.07] text-emerald-300"
                    : streamMode === "offline"
                      ? "border-red-400/20 bg-red-400/[0.06] text-red-300"
                      : "border-amber-400/20 bg-amber-400/[0.06] text-amber-300"
                }`}
              >
                {streamLabel(streamMode)}
              </span>
            </div>

            <button
              type="button"
              onClick={() => navigator.clipboard.writeText(address)}
              className="mt-1 flex items-center gap-1 text-[10px] text-zinc-700 hover:text-zinc-400"
            >
              {short(address)}
              <Copy className="h-3 w-3" />
            </button>
          </div>
        </div>

        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={toggleWatchlist}
            className={`rounded-lg border p-2 ${
              saved
                ? "border-emerald-400/20 bg-emerald-400/10 text-emerald-300"
                : "border-white/10 text-zinc-500 hover:text-white"
            }`}
            title="Watchlist"
          >
            {saved ? <BookmarkCheck className="h-4 w-4" /> : <Bookmark className="h-4 w-4" />}
          </button>

          {mode === "modal" && (
            <Link
              href={`/token/${address}`}
              data-native-terminal-full="true"
              className="rounded-lg border border-white/10 p-2 text-zinc-500 hover:text-white"
              title="Open full terminal"
            >
              <Maximize2 className="h-4 w-4" />
            </Link>
          )}

          <button
            type="button"
            onClick={() => void load()}
            className="rounded-lg border border-white/10 p-2 text-zinc-500 hover:text-white"
            title="Refresh history"
          >
            <RefreshCw className={`h-4 w-4 ${loading ? "animate-spin" : ""}`} />
          </button>

          {mode === "modal" && (
            <button
              type="button"
              onClick={onClose}
              className="rounded-lg border border-white/10 p-2 text-zinc-500 hover:text-white"
              title="Close"
            >
              <X className="h-4 w-4" />
            </button>
          )}
        </div>
      </header>

      <div className={mode === "modal" ? "overflow-y-auto p-3 lg:p-4" : ""}>
        {error && (
          <div className="mb-3 rounded-xl border border-amber-400/15 bg-amber-400/[0.04] p-3 text-xs text-amber-200/80">
            {error}
          </div>
        )}

        <section className="mb-3 grid grid-cols-2 gap-2 sm:grid-cols-4">
          <div className="rounded-xl border border-white/10 bg-white/[0.025] p-3">
            <div className="text-[9px] uppercase tracking-[0.13em] text-zinc-700">
              {metric === "price" ? "Price" : "Market Cap"}
            </div>
            <div className="mt-1 text-sm font-semibold text-white">
              {quote === "usd" ? money(currentValue) : solText(currentValue)}
            </div>
          </div>
          <div className="rounded-xl border border-white/10 bg-white/[0.025] p-3">
            <div className="text-[9px] uppercase tracking-[0.13em] text-zinc-700">Liquidity</div>
            <div className="mt-1 text-sm font-semibold text-white">
              {money(data?.selectedPool.liquidityUsd)}
            </div>
          </div>
          <div className="rounded-xl border border-white/10 bg-white/[0.025] p-3">
            <div className="text-[9px] uppercase tracking-[0.13em] text-zinc-700">24h Volume</div>
            <div className="mt-1 text-sm font-semibold text-white">
              {money(data?.selectedPool.volume.h24)}
            </div>
          </div>
          <div className="rounded-xl border border-white/10 bg-white/[0.025] p-3">
            <div className="text-[9px] uppercase tracking-[0.13em] text-zinc-700">Live trades</div>
            <div className="mt-1 text-sm font-semibold text-emerald-300">{liveTrades.length}</div>
          </div>
        </section>

        <section className="mx-auto mb-3 max-w-[1080px] overflow-hidden rounded-2xl border border-white/10 bg-[#090b0f]">
          <div className="flex flex-wrap items-center justify-between gap-2 border-b border-white/5 px-3 py-2.5">
            <div className="flex flex-wrap items-center gap-1">
              <button
                type="button"
                onClick={() => setMetric("price")}
                className={`rounded-md px-2.5 py-1.5 text-[10px] ${
                  metric === "price" ? "bg-white text-black" : "text-zinc-500 hover:bg-white/5"
                }`}
              >
                PRICE
              </button>
              <button
                type="button"
                onClick={() => setMetric("mcap")}
                className={`rounded-md px-2.5 py-1.5 text-[10px] ${
                  metric === "mcap" ? "bg-white text-black" : "text-zinc-500 hover:bg-white/5"
                }`}
              >
                MCAP
              </button>
              <span className="mx-1 h-4 w-px bg-white/10" />
              <button
                type="button"
                onClick={() => setQuote("usd")}
                className={`rounded-md px-2.5 py-1.5 text-[10px] ${
                  quote === "usd" ? "bg-emerald-400/10 text-emerald-300" : "text-zinc-600 hover:text-white"
                }`}
              >
                USD
              </button>
              <button
                type="button"
                onClick={() => setQuote("sol")}
                className={`rounded-md px-2.5 py-1.5 text-[10px] ${
                  quote === "sol" ? "bg-violet-400/10 text-violet-300" : "text-zinc-600 hover:text-white"
                }`}
              >
                SOL
              </button>
            </div>

            <div className="flex flex-wrap items-center gap-1">
              {TIMEFRAMES.map((item) => (
                <button
                  key={item}
                  type="button"
                  onClick={() => void switchTimeframe(item)}
                  className={`rounded-md px-2 py-1.5 text-[10px] ${
                    timeframe === item ? "bg-white/10 text-white" : "text-zinc-600 hover:text-white"
                  }`}
                >
                  {item}
                </button>
              ))}
            </div>
          </div>

          <div className="relative px-2 py-2">
            {displayCandles.length === 0 && (
              <div className="pointer-events-none absolute inset-0 z-10 flex items-center justify-center text-xs text-zinc-600">
                Waiting for market candles / first live swap...
              </div>
            )}
            <MemeScopeLiveChart
              candles={displayCandles}
              seriesKey={`${address}-${data?.selectedPool.address ?? "none"}-${metric}-${quote}-${timeframe}`}
              height={350}
            />
          </div>
        </section>

        {data && data.pools.length > 1 && (
          <section className="mx-auto mb-3 flex max-w-[1080px] gap-2 overflow-x-auto pb-1">
            {data.pools.slice(0, 8).map((item) => (
              <button
                key={item.address}
                type="button"
                onClick={() => void switchPool(item.address)}
                className={`shrink-0 rounded-lg border px-3 py-2 text-left text-[10px] ${
                  item.address === data.selectedPool.address
                    ? "border-emerald-400/20 bg-emerald-400/[0.06] text-emerald-300"
                    : "border-white/10 text-zinc-600 hover:text-white"
                }`}
              >
                <div>{item.dexName}</div>
                <div className="mt-0.5 text-[9px] opacity-70">Liq {money(item.liquidityUsd)}</div>
              </button>
            ))}
          </section>
        )}

        <section className="mx-auto max-w-[1080px] overflow-hidden rounded-2xl border border-white/10 bg-white/[0.02]">
          <div className="flex items-center justify-between border-b border-white/5 px-4 py-3">
            <div>
              <div className="text-sm font-semibold text-white">Transactions</div>
              <div className="mt-1 text-[10px] text-zinc-700">
                Live rows are pushed from MemeScope market engine; no browser polling.
              </div>
            </div>
            <div className="text-[10px] text-zinc-700">{transactions.length} rows</div>
          </div>

          <div className="max-h-[420px] overflow-auto">
            <table className="w-full min-w-[820px] text-left text-xs">
              <thead className="sticky top-0 z-10 bg-[#0c0f14] text-[9px] uppercase tracking-[0.12em] text-zinc-700">
                <tr>
                  <th className="px-4 py-2.5">Time</th>
                  <th className="px-3 py-2.5">Type</th>
                  <th className="px-3 py-2.5">USD</th>
                  <th className="px-3 py-2.5">SOL</th>
                  <th className="px-3 py-2.5">Price USD</th>
                  <th className="px-3 py-2.5">Price SOL</th>
                  <th className="px-3 py-2.5">Maker</th>
                  <th className="px-3 py-2.5">Tx</th>
                </tr>
              </thead>
              <tbody>
                {transactions.map((trade) => (
                  <tr
                    key={trade.key}
                    className={`border-t border-white/5 ${trade.live ? "bg-emerald-400/[0.015]" : ""}`}
                  >
                    <td className="px-4 py-2.5 text-zinc-600">
                      <span className="flex items-center gap-1.5">
                        {clock(trade.timestamp)}
                        {trade.live && (
                          <span className="rounded bg-emerald-400/10 px-1 py-0.5 text-[8px] text-emerald-300">LIVE</span>
                        )}
                      </span>
                    </td>
                    <td
                      className={`px-3 py-2.5 font-semibold uppercase ${
                        trade.side === "buy"
                          ? "text-emerald-300"
                          : trade.side === "sell"
                            ? "text-red-300"
                            : "text-zinc-500"
                      }`}
                    >
                      {trade.side}
                      {trade.estimated && (
                        <span className="ml-1 text-[8px] font-normal text-amber-400/60">EST</span>
                      )}
                    </td>
                    <td className="px-3 py-2.5 text-zinc-300">{money(trade.usd)}</td>
                    <td className="px-3 py-2.5 text-zinc-300">{solText(trade.sol)}</td>
                    <td className="px-3 py-2.5 font-mono text-[10px] text-zinc-500">{money(trade.priceUsd)}</td>
                    <td className="px-3 py-2.5 font-mono text-[10px] text-zinc-500">{solText(trade.priceSol)}</td>
                    <td className="px-3 py-2.5 font-mono text-[10px] text-zinc-600">
                      {trade.maker ? short(trade.maker) : "N/A"}
                    </td>
                    <td className="px-3 py-2.5">
                      {trade.signature ? (
                        <a
                          href={`https://solscan.io/tx/${trade.signature}`}
                          target="_blank"
                          rel="noreferrer"
                          className="text-zinc-600 hover:text-white"
                        >
                          <ExternalLink className="h-3.5 w-3.5" />
                        </a>
                      ) : (
                        <span className="text-zinc-800">N/A</span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>

            {transactions.length === 0 && (
              <div className="p-10 text-center text-xs text-zinc-600">
                Waiting for the first transaction from this pool...
              </div>
            )}
          </div>
        </section>

        <div className="mx-auto mt-3 max-w-[1080px] text-[9px] leading-4 text-zinc-700">
          Processed Enhanced WebSocket is the lowest-latency mode used here. Standard WebSocket + RPC is the automatic fallback. “EST” marks a row where quote value had to be estimated from the latest market snapshot.
        </div>
      </div>
    </div>
  );

  return main;
}

'@
Write-Utf8NoBom "src/components/token-market-terminal.tsx" $file_5

$file_6 = @'
"use client";

import { useEffect, useState } from "react";

import { TokenMarketTerminal } from "@/components/token-market-terminal";

export function TokenQuickView() {
  const [address, setAddress] = useState<string | null>(null);

  useEffect(() => {
    const onClick = (event: MouseEvent) => {
      if (
        event.defaultPrevented ||
        event.button !== 0 ||
        event.metaKey ||
        event.ctrlKey ||
        event.shiftKey ||
        event.altKey
      ) {
        return;
      }

      const target = event.target;
      if (!(target instanceof Element)) return;

      const anchor = target.closest("a") as HTMLAnchorElement | null;
      if (!anchor || anchor.dataset.nativeTerminalFull === "true") return;

      let url: URL;
      try {
        url = new URL(anchor.href, window.location.origin);
      } catch {
        return;
      }

      if (url.origin !== window.location.origin) return;

      const match = url.pathname.match(/^\/token\/([^/]+)\/?$/);
      if (!match) return;

      event.preventDefault();
      event.stopPropagation();
      setAddress(decodeURIComponent(match[1]));
    };

    const onCustom = (event: Event) => {
      const detail = (event as CustomEvent<string>).detail;
      if (detail) setAddress(detail);
    };

    document.addEventListener("click", onClick, true);
    window.addEventListener("memescope:open-token", onCustom as EventListener);

    return () => {
      document.removeEventListener("click", onClick, true);
      window.removeEventListener("memescope:open-token", onCustom as EventListener);
    };
  }, []);

  useEffect(() => {
    if (!address) return;

    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";

    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") setAddress(null);
    };

    window.addEventListener("keydown", onKey);

    return () => {
      document.body.style.overflow = previous;
      window.removeEventListener("keydown", onKey);
    };
  }, [address]);

  if (!address) return null;

  return (
    <div
      className="fixed inset-0 z-[100] flex items-center justify-center bg-black/75 p-2 backdrop-blur-sm lg:p-5"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) setAddress(null);
      }}
    >
      <div className="w-full max-w-[1280px]">
        <TokenMarketTerminal
          key={address}
          address={address}
          mode="modal"
          onClose={() => setAddress(null)}
        />
      </div>
    </div>
  );
}

'@
Write-Utf8NoBom "src/components/token-quick-view.tsx" $file_6

$file_7 = @'
"use client";

import { useParams } from "next/navigation";

import { TokenMarketTerminal } from "@/components/token-market-terminal";

export default function TokenPage() {
  const params = useParams<{ address: string }>();
  const address = params.address;

  return <TokenMarketTerminal address={address} mode="page" />;
}

'@
Write-Utf8NoBom "src/app/token/[address]/page.tsx" $file_7

# ---------------------------------------------------------
# Persistent global quick-view: every internal /token/... link
# opens the live chart + transactions modal from any menu.
# ---------------------------------------------------------
$appShellPath = Join-Path $root "src/components/app-shell.tsx"

if (Test-Path -LiteralPath $appShellPath) {
    $shell = [System.IO.File]::ReadAllText($appShellPath)

    if ($shell -notmatch 'token-quick-view') {
        $shell = "import { TokenQuickView } from `"@/components/token-quick-view`";`r`n" + $shell
    }

    if ($shell -notmatch '<TokenQuickView\s*/>') {
        if ($shell.Contains('<MobileNav />')) {
            $shell = $shell.Replace(
                '<MobileNav />',
                "<MobileNav />`r`n        <TokenQuickView />"
            )
        } else {
            throw "AppShell was found, but <MobileNav /> marker is missing. Backup preserved at $backupDir"
        }
    }

    [System.IO.File]::WriteAllText($appShellPath, $shell, $utf8NoBom)
    Write-Host "Global token quick-view attached to AppShell." -ForegroundColor Green
}

# ---------------------------------------------------------
# Scanner: token symbol itself becomes clickable.
# Existing Analyze / token links are also intercepted globally.
# ---------------------------------------------------------
$scannerPath = Join-Path $root "src/app/scanner/page.tsx"

if (Test-Path -LiteralPath $scannerPath) {
    $scanner = [System.IO.File]::ReadAllText($scannerPath)

    $oldScannerSymbol = @'
          <span className="max-w-[120px] truncate font-semibold text-white">
            {token.symbol}
          </span>
'@

    $newScannerSymbol = @'
          <Link
            href={`/token/${token.address}`}
            className="max-w-[120px] truncate font-semibold text-white hover:text-emerald-300"
          >
            {token.symbol}
          </Link>
'@

    if ($scanner.Contains($oldScannerSymbol)) {
        $scanner = $scanner.Replace($oldScannerSymbol, $newScannerSymbol)
        [System.IO.File]::WriteAllText($scannerPath, $scanner, $utf8NoBom)
        Write-Host "Scanner token symbols now open live terminal." -ForegroundColor Green
    } elseif ($scanner -match 'href=\{`/token/\$\{token\.address\}`\}') {
        Write-Host "Scanner already contains token links." -ForegroundColor DarkGray
    } else {
        Write-Host "Scanner identity pattern differs; existing /token links still work globally." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------
# Discover: token symbol itself becomes clickable.
# ---------------------------------------------------------
$discoverPath = Join-Path $root "src/app/discover/page.tsx"

if (Test-Path -LiteralPath $discoverPath) {
    $discover = [System.IO.File]::ReadAllText($discoverPath)

    $oldDiscoverSymbol = @'
              <h3 className="truncate text-base font-semibold text-white">
                {token.symbol}
              </h3>
'@

    $newDiscoverSymbol = @'
              <Link
                href={`/token/${token.address}`}
                className="truncate text-base font-semibold text-white hover:text-emerald-300"
              >
                {token.symbol}
              </Link>
'@

    if ($discover.Contains($oldDiscoverSymbol)) {
        $discover = $discover.Replace($oldDiscoverSymbol, $newDiscoverSymbol)
        [System.IO.File]::WriteAllText($discoverPath, $discover, $utf8NoBom)
        Write-Host "Discover token symbols now open live terminal." -ForegroundColor Green
    } elseif ($discover -match 'href=\{`/token/\$\{token\.address\}`\}') {
        Write-Host "Discover already contains token links." -ForegroundColor DarkGray
    } else {
        Write-Host "Discover identity pattern differs; existing /token links still work globally." -ForegroundColor Yellow
    }
}

Remove-Item -Recurse -Force (Join-Path $root ".next") -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host " Stage 14 installed" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Included:" -ForegroundColor Cyan
Write-Host " - MemeScope server-side live market stream"
Write-Host " - Helius Enhanced transactionSubscribe at processed commitment when available"
Write-Host " - automatic standard logsSubscribe + RPC fallback"
Write-Host " - no browser polling for live transaction rows"
Write-Host " - live BUY / SELL, USD, SOL, price USD, price SOL"
Write-Host " - live candles built from streamed swaps"
Write-Host " - PRICE / MCAP switch"
Write-Host " - USD / SOL switch"
Write-Host " - centered 350px chart"
Write-Host " - global token modal from Scanner, Discover and every internal /token link"
Write-Host " - full-page terminal remains available"
Write-Host ""
Write-Host "Run next:" -ForegroundColor Cyan
Write-Host "npm run typecheck"
Write-Host "npm run dev"
Write-Host ""
