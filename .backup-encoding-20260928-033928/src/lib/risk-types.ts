export type RiskSeverity = "good" | "info" | "warning" | "danger";

export type RiskFlag = {
  id: string;
  title: string;
  description: string;
  severity: RiskSeverity;
  points: number;
};

export type OwnerConcentration = {
  owner: string;
  amount: number;
  percentage: number;
};

export type SolanaRiskReport = {
  ok: boolean;
  tokenAddress: string;
  tokenProgram: string | null;
  tokenStandard: "SPL Token" | "Token-2022" | "Unknown";
  mintAuthority: string | null;
  freezeAuthority: string | null;
  mintAuthorityDisabled: boolean | null;
  freezeAuthorityDisabled: boolean | null;
  decimals: number | null;
  supply: number;
  top1Percentage: number;
  top5Percentage: number;
  top10Percentage: number;
  analyzedOwnerCount: number;
  topOwners: OwnerConcentration[];
  riskScore: number;
  riskLabel: "Low" | "Moderate" | "High";
  flags: RiskFlag[];
  market: {
    pairAddress: string | null;
    dexId: string | null;
    dexUrl: string | null;
    name: string | null;
    symbol: string | null;
    priceUsd: number;
    marketCap: number;
    fdv: number;
    liquidity: number;
    liquidityToMarketCap: number | null;
    volume5m: number;
    buys5m: number;
    sells5m: number;
    pairCreatedAt: number | null;
    pairAgeMinutes: number | null;
  };
  rpcSource: string;
  updatedAt: number;
  limitations: string[];
  error?: string;
};
