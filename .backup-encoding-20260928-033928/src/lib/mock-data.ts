export type RiskLevel = "Low" | "Medium" | "High";

export type MemeToken = {
  address: string;
  name: string;
  symbol: string;
  chain: string;
  ageMinutes: number;
  priceUsd: number;
  marketCap: number;
  liquidity: number;
  volume5m: number;
  volume1h: number;
  buys5m: number;
  sells5m: number;
  priceChange5m: number;
  priceChange1h: number;
  score: number;
  momentum: number;
  activity: number;
  liquidityScore: number;
  safety: number;
  risk: RiskLevel;
};

export const mockTokens: MemeToken[] = [
  {
    address: "9hQ2wR8mZsK1alpha",
    name: "Moon Cat",
    symbol: "MCAT",
    chain: "Solana",
    ageMinutes: 47,
    priceUsd: 0.0000914,
    marketCap: 91420,
    liquidity: 31810,
    volume5m: 27510,
    volume1h: 84100,
    buys5m: 83,
    sells5m: 26,
    priceChange5m: 14.8,
    priceChange1h: 62.1,
    score: 82,
    momentum: 91,
    activity: 86,
    liquidityScore: 74,
    safety: 63,
    risk: "Medium",
  },
  {
    address: "6pA1kQ9SolBeta",
    name: "Pepe Matrix",
    symbol: "PMX",
    chain: "Solana",
    ageMinutes: 133,
    priceUsd: 0.000142,
    marketCap: 142300,
    liquidity: 54110,
    volume5m: 31190,
    volume1h: 118400,
    buys5m: 116,
    sells5m: 41,
    priceChange5m: 9.1,
    priceChange1h: 34.2,
    score: 87,
    momentum: 88,
    activity: 92,
    liquidityScore: 82,
    safety: 77,
    risk: "Low",
  },
  {
    address: "0xcatdogbasegamma",
    name: "Dog With Cat",
    symbol: "DWC",
    chain: "Base",
    ageMinutes: 310,
    priceUsd: 0.000281,
    marketCap: 281000,
    liquidity: 72300,
    volume5m: 44700,
    volume1h: 196000,
    buys5m: 91,
    sells5m: 48,
    priceChange5m: 5.4,
    priceChange1h: 22.5,
    score: 79,
    momentum: 80,
    activity: 84,
    liquidityScore: 86,
    safety: 66,
    risk: "Medium",
  },
  {
    address: "7rugdogSolDelta",
    name: "Rug Dog",
    symbol: "RUGD",
    chain: "Solana",
    ageMinutes: 26,
    priceUsd: 0.000421,
    marketCap: 421000,
    liquidity: 9100,
    volume5m: 60100,
    volume1h: 99800,
    buys5m: 54,
    sells5m: 49,
    priceChange5m: -8.7,
    priceChange1h: 101.5,
    score: 34,
    momentum: 61,
    activity: 71,
    liquidityScore: 21,
    safety: 18,
    risk: "High",
  },
  {
    address: "0xbananaethomega",
    name: "Banana Brain",
    symbol: "BRAIN",
    chain: "Ethereum",
    ageMinutes: 990,
    priceUsd: 0.00182,
    marketCap: 728000,
    liquidity: 188000,
    volume5m: 21900,
    volume1h: 241000,
    buys5m: 39,
    sells5m: 25,
    priceChange5m: 3.2,
    priceChange1h: 18.8,
    score: 76,
    momentum: 72,
    activity: 74,
    liquidityScore: 91,
    safety: 74,
    risk: "Low",
  },
  {
    address: "4frogSolTheta",
    name: "Frog Terminal",
    symbol: "FROGT",
    chain: "Solana",
    ageMinutes: 78,
    priceUsd: 0.000064,
    marketCap: 64000,
    liquidity: 28700,
    volume5m: 16700,
    volume1h: 63800,
    buys5m: 67,
    sells5m: 19,
    priceChange5m: 18.2,
    priceChange1h: 44.7,
    score: 84,
    momentum: 94,
    activity: 82,
    liquidityScore: 70,
    safety: 69,
    risk: "Medium",
  },
];
