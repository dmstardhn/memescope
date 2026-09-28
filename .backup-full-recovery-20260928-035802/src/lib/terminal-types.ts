export type TerminalSourceFlags = {
  latestProfile: boolean;
  recentUpdate: boolean;
  boostedLatest: boolean;
  boostedTop: boolean;
  communityTakeover: boolean;
  advertised: boolean;
};

export type TerminalToken = {
  address: string;
  pairAddress: string;
  dexId: string;
  dexUrl: string | null;

  symbol: string;
  name: string;
  imageUrl: string | null;

  priceUsd: number | null;
  priceNative: number | null;

  priceChange: {
    m5: number | null;
    h1: number | null;
    h6: number | null;
    h24: number | null;
  };

  volume: {
    m5: number;
    h1: number;
    h6: number;
    h24: number;
  };

  txns: {
    m5: {
      buys: number;
      sells: number;
    };
    h1: {
      buys: number;
      sells: number;
    };
    h6: {
      buys: number;
      sells: number;
    };
    h24: {
      buys: number;
      sells: number;
    };
  };

  liquidityUsd: number;
  marketCap: number | null;
  fdv: number | null;

  pairCreatedAt: number | null;
  pairAgeMinutes: number | null;

  boostsActive: number;
  boostAmount: number;
  boostTotalAmount: number;

  websites: string[];

  socials: Array<{
    platform: string;
    handle: string;
  }>;

  sources: TerminalSourceFlags;

  volumeSpike5m: number | null;
  buyShare5m: number | null;
  liquidityToMcap: number | null;

  activityScore: number;
};

export type TerminalResponse = {
  generatedAt: number;
  tokenCount: number;
  sourceCount: number;
  tokens: TerminalToken[];
  warnings: string[];
};