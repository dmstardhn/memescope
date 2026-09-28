export type DexPair = {
  chainId?: string;
  dexId?: string;
  url?: string;
  pairAddress?: string;
  labels?: string[];
  baseToken?: {
    address?: string;
    name?: string;
    symbol?: string;
  };
  quoteToken?: {
    address?: string;
    name?: string;
    symbol?: string;
  };
  priceNative?: string;
  priceUsd?: string | null;
  txns?: Record<
    string,
    {
      buys?: number;
      sells?: number;
    }
  >;
  volume?: Record<string, number>;
  priceChange?: Record<string, number> | null;
  liquidity?: {
    usd?: number | null;
    base?: number;
    quote?: number;
  } | null;
  fdv?: number | null;
  marketCap?: number | null;
  pairCreatedAt?: number | null;
  info?: {
    imageUrl?: string | null;
    websites?: Array<{ url?: string }>;
    socials?: Array<{ platform?: string; handle?: string }>;
  };
  boosts?: {
    active?: number;
  };
};

export type LiveToken = {
  chainId: "solana";
  dexId: string;
  pairAddress: string;
  tokenAddress: string;
  name: string;
  symbol: string;
  quoteSymbol: string;
  imageUrl: string | null;
  dexUrl: string;
  priceUsd: number;
  marketCap: number;
  fdv: number;
  liquidity: number;
  volume5m: number;
  volume1h: number;
  volume6h: number;
  volume24h: number;
  buys5m: number;
  sells5m: number;
  buys1h: number;
  sells1h: number;
  priceChange5m: number;
  priceChange1h: number;
  priceChange6h: number;
  priceChange24h: number;
  pairCreatedAt: number | null;
  ageMinutes: number | null;
  boosts: number;
  score: number;
  riskLabel: "Lower" | "Medium" | "Higher";
};

export type SolanaMarketResponse = {
  ok: boolean;
  source: string;
  mode: string;
  refreshMs: number;
  discoveryRefreshMs: number;
  updatedAt: number;
  discovered: number;
  tokens: LiveToken[];
  error?: string;
};
